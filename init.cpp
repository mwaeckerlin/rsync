/**

init: minimal, shell-free entrypoint of mwaeckerlin/rsync.

The runtime image contains no shell, no perl, no busybox — only rsync, its
shared libraries and this program.

Behaviour:

  1. Without RSYNCD_MODULES, one synchronisation: rsync with RSYNC_OPTIONS
     (default "-avP --delete", separated by white space) followed by the
     arguments of the container.
  2. With RSYNCD_MODULES, the rsync daemon: every entry, separated by white
     space, is name=path (read only, as in rsync), name=path:ro or
     name=path:rw. All entries are checked first, then written to
     /run/rsyncd/rsyncd.conf and printed to the log; rsync then runs
     --daemon --no-detach on port 8873 with that configuration, followed by
     the arguments of the container.

A name holds letters, digits, '.', '_' and '-', a path starts with '/' and
holds the same characters and '/', so no value can add a parameter or a
module of its own to the configuration.

*/

#include <unistd.h>

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr const char *RSYNC      = "/usr/bin/rsync";
constexpr const char *CONF_PATH  = "/run/rsyncd/rsyncd.conf";
constexpr const char *NAME_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-";
constexpr const char *PATH_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/";

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

bool
only(const std::string &value, const char *allowed) {
  return !value.empty() && value.find_first_not_of(allowed) == std::string::npos;
}

struct Module {
  std::string name, path;
  bool writable;
};

std::runtime_error
invalid(const std::string &entry, const std::string &why) {
  return std::runtime_error("invalid RSYNCD_MODULES entry '" + entry + "': " + why);
}

Module
module(const std::string &entry) {
  const auto equals = entry.find('=');
  if (equals == std::string::npos) throw invalid(entry, "write name=path, name=path:ro or name=path:rw");
  Module m{entry.substr(0, equals), entry.substr(equals + 1), false};
  const std::string mode = m.path.size() > 3 ? m.path.substr(m.path.size() - 3) : std::string();
  if (mode == ":rw" || mode == ":ro") {
    m.writable = mode == ":rw";
    m.path.resize(m.path.size() - 3);
  }
  if (!only(m.name, NAME_CHARS)) throw invalid(entry, "a name holds letters, digits, '.', '_' and '-' only");
  std::string lower;
  for (unsigned char c : m.name) lower += static_cast<char>(std::tolower(c));
  if (lower == "global") throw invalid(entry, "'global' is the section of the global parameters of rsync");
  if (!only(m.path, PATH_CHARS) || m.path[0] != '/')
    throw invalid(entry, "a path starts with '/' and holds letters, digits, '/', '.', '_' and '-' only");
  return m;
}

} // namespace

int main(int argc, char *argv[]) try {
  std::vector<std::string> command{RSYNC};
  const auto entries = words(env_or("RSYNCD_MODULES"));
  if (entries.empty()) {
    for (const auto &option : words(env_or("RSYNC_OPTIONS", "-avP --delete"))) command.push_back(option);
  } else {
    std::set<std::string> names;
    std::string conf = "log file = /dev/stdout\nuse chroot = no\n";
    for (const auto &entry : entries) {
      const Module m = module(entry);
      if (!names.insert(m.name).second) throw invalid(entry, "the module " + m.name + " is given twice");
      conf += "\n[" + m.name + "]\npath = " + m.path + "\nread only = " + (m.writable ? "no" : "yes") + "\n";
    }
    std::ofstream out(CONF_PATH, std::ios::binary | std::ios::trunc);
    out << conf;
    out.close();
    if (!out) throw std::runtime_error(std::string("cannot write the daemon configuration ") + CONF_PATH);
    std::cerr << "**** " << CONF_PATH << ":\n" << conf << std::flush;
    command.insert(command.end(), {"--daemon", "--no-detach", "--port=8873", std::string("--config=") + CONF_PATH});
  }
  command.insert(command.end(), argv + 1, argv + argc);

  std::vector<char *> exec_argv;
  for (auto &arg : command) exec_argv.push_back(arg.data());
  exec_argv.push_back(nullptr);
  execv(RSYNC, exec_argv.data());
  std::perror(RSYNC);
  return 1;
} catch (const std::exception &e) {
  std::cerr << "**** ERROR: " << e.what() << std::endl;
  return 1;
} catch (...) {
  std::cerr << "**** UNKNOWN ERROR" << std::endl;
  return 1;
}
