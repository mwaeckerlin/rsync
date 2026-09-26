/**

rsync-watch: minimal, shell-free entrypoint of mwaeckerlin/rsync:inotify.

Synchronises once at start, then again whenever inotifywait reports a change
below the watched directories. The runtime image contains no shell, no perl,
no busybox — only rsync, inotifywait, their shared libraries and this program.

Behaviour:

  1. The rsync command line is RSYNC_OPTIONS (default "-avP --delete")
     followed by the arguments of the container, so the arguments are the
     same as for mwaeckerlin/rsync. At least a source and a destination are
     required.
  2. WATCH names the directories to watch, separated by white space; without
     it every argument that is not an option is watched, except the last one,
     which is the destination.
  3. inotifywait -m -r runs for the whole life of the container. Once it
     reports that its watches are established, the first synchronisation
     runs, so no change between the start and the watch is lost.
  4. A change starts a run after DELAY seconds (default 2) without a further
     change, so a burst of changes becomes one run. Changes during a run lead
     to one more run after it.
  5. A failed run is logged and the watch goes on; the next change retries.
  6. SIGTERM and SIGINT are passed on to inotifywait and a running rsync, and
     the program ends with exit code 0 once every child has ended.

As PID 1 it also reaps the processes rsync leaves behind.

*/

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr const char *RSYNC       = "/usr/bin/rsync";
constexpr const char *INOTIFYWAIT = "/usr/bin/inotifywait";
constexpr const char *ESTABLISHED = "Watches established.";
constexpr const char *EVENTS      = "close_write,create,delete,move,attrib";

using Clock = std::chrono::steady_clock;
using std::chrono::milliseconds;

volatile sig_atomic_t stop_signal = 0;

void
on_signal(int sig) {
  stop_signal = sig;
}

std::string
env_or(const char *name, const std::string &fallback = {}) {
  const char *v = std::getenv(name);
  return (v && *v) ? std::string(v) : fallback;
}

std::vector<std::string>
words(const std::string &text) {
  std::istringstream in(text);
  std::vector<std::string> result;
  for (std::string word; in >> word;) result.push_back(word);
  return result;
}

// Whole seconds only; nine digits keep the value far inside an int and allow
// more than thirty years, which is no limit in practice.
int
seconds(const char *name, const std::string &value) {
  if (value.find_first_not_of("0123456789") != std::string::npos || value.size() > 9)
    throw std::runtime_error(std::string(name) + " must be a whole number of seconds, got '" + value + "'");
  return std::stoi(value);
}

std::vector<std::string>
paths(const std::vector<std::string> &args) {
  std::vector<std::string> result;
  std::copy_if(args.begin(), args.end(), std::back_inserter(result),
               [](const std::string &arg) { return !arg.empty() && arg[0] != '-'; });
  return result;
}

pid_t
spawn(const std::vector<std::string> &args, int out = -1, int err = -1) {
  std::vector<char *> argv;
  for (const auto &arg : args) argv.push_back(const_cast<char *>(arg.c_str()));
  argv.push_back(nullptr);
  const pid_t pid = fork();
  if (pid < 0) throw std::runtime_error(std::string("fork: ") + std::strerror(errno));
  if (pid == 0) {
    if (out >= 0) dup2(out, STDOUT_FILENO);
    if (err >= 0) dup2(err, STDERR_FILENO);
    execv(argv[0], argv.data());
    std::perror(argv[0]);
    _exit(127);
  }
  return pid;
}

std::string
outcome(int status) {
  if (WIFEXITED(status)) return "exit code " + std::to_string(WEXITSTATUS(status));
  if (WIFSIGNALED(status)) return "signal " + std::to_string(WTERMSIG(status));
  return "status " + std::to_string(status);
}

} // namespace

int main(int argc, char *argv[]) try {
  const std::vector<std::string> args(argv + 1, argv + argc);
  const auto delay = milliseconds(1000LL * seconds("DELAY", env_or("DELAY", "2")));

  const auto given = paths(args);
  if (given.size() < 2)
    throw std::runtime_error("give the source and the destination as arguments, e.g. /source/ /target/");

  std::vector<std::string> rsync{RSYNC};
  for (const auto &option : words(env_or("RSYNC_OPTIONS", "-avP --delete"))) rsync.push_back(option);
  rsync.insert(rsync.end(), args.begin(), args.end());

  auto watch = words(env_or("WATCH"));
  if (watch.empty()) watch.assign(given.begin(), given.end() - 1);

  struct sigaction action {};
  action.sa_handler = on_signal;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, nullptr);
  sigaction(SIGINT, &action, nullptr);

  int events[2], messages[2];
  if (pipe2(events, O_CLOEXEC) || pipe2(messages, O_CLOEXEC))
    throw std::runtime_error(std::string("pipe: ") + std::strerror(errno));

  std::vector<std::string> inotify{INOTIFYWAIT, "-m", "-r", "-e", EVENTS, "--format", "%w%f", "--"};
  inotify.insert(inotify.end(), watch.begin(), watch.end());
  const pid_t watcher = spawn(inotify, events[1], messages[1]);
  close(events[1]);
  close(messages[1]);

  std::cerr << "**** Watching";
  for (const auto &dir : watch) std::cerr << ' ' << dir;
  std::cerr << ", delay " << delay.count() / 1000 << "s" << std::endl;

  pid_t running = 0;
  bool established = false, initial = true, pending = false;
  long changes = 0;
  Clock::time_point last_change{};
  std::string message; // inotifywait's standard error until its watches stand
  pollfd fds[2] = {{events[0], POLLIN, 0}, {messages[0], POLLIN, 0}};
  char buffer[4096];

  const auto start = [&](const std::string &why) {
    std::cerr << "**** Synchronising: " << why << std::endl;
    running = spawn(rsync);
    pending = false;
    changes = 0;
  };

  while (true) {
    // SIGCHLD does not interrupt poll, so a running rsync is looked after
    // every tenth of a second; SIGTERM does interrupt it.
    long long timeout = running ? 100 : 1000;
    if (!running && pending)
      timeout = std::max<long long>(0, std::chrono::duration_cast<milliseconds>(last_change + delay - Clock::now()).count());
    if (poll(fds, 2, static_cast<int>(std::min<long long>(timeout, INT_MAX))) < 0 && errno != EINTR)
      throw std::runtime_error(std::string("poll: ") + std::strerror(errno));

    if (fds[0].revents & (POLLIN | POLLHUP)) {
      const ssize_t n = read(events[0], buffer, sizeof buffer);
      if (n > 0) {
        changes += std::count(buffer, buffer + n, '\n');
        pending = true;
        last_change = Clock::now();
      } else if (n == 0) {
        fds[0].fd = -1; // inotifywait has ended; it is reaped below
      }
    }
    if (fds[1].revents & (POLLIN | POLLHUP)) {
      const ssize_t n = read(messages[0], buffer, sizeof buffer);
      if (n > 0) {
        std::cerr.write(buffer, n).flush();
        if (!established) {
          message.append(buffer, n);
          established = message.find(ESTABLISHED) != std::string::npos;
        }
      } else if (n == 0) {
        fds[1].fd = -1;
      }
    }

    if (stop_signal) {
      std::cerr << "**** Stopping on signal " << stop_signal << std::endl;
      kill(watcher, SIGTERM);
      if (running) kill(running, SIGTERM);
      while (waitpid(-1, nullptr, 0) > 0 || errno == EINTR) {}
      return 0;
    }

    for (int status; true;) {
      const pid_t pid = waitpid(-1, &status, WNOHANG);
      if (pid <= 0) break;
      if (pid == running) {
        running = 0;
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
          std::cerr << "**** Synchronisation finished" << std::endl;
        else
          std::cerr << "**** Synchronisation failed with " << outcome(status) << std::endl;
      } else if (pid == watcher) {
        throw std::runtime_error("inotifywait ended with " + outcome(status));
      }
    }

    if (!running && established && initial) {
      initial = false;
      start("initial run");
    } else if (!running && !initial && pending && Clock::now() - last_change >= delay) {
      start(std::to_string(changes) + " changes");
    }
  }
} catch (const std::exception &e) {
  std::cerr << "**** ERROR: " << e.what() << std::endl;
  return 1;
} catch (...) {
  std::cerr << "**** UNKNOWN ERROR" << std::endl;
  return 1;
}
