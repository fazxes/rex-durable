/*
 * A stand-in for fx, Claude Code, or Codex in the end-to-end test. It keeps
 * its conversation's file the way the real program does, then waits:
 *
 *   fx      holds FAKE_HOME/.fx/sessions/v2/<id>/lock open
 *   codex   holds FAKE_HOME/.codex/sessions/.../rollout-<time>-<id>.jsonl open
 *   claude  writes FAKE_HOME/.claude/projects/<folder>/<id>.jsonl and closes it
 *   pi      writes nothing and blanks its arguments, as pi on --session does
 *
 * With --write-pid-file, claude also writes FAKE_HOME/.claude/sessions/<pid>.json
 * like Claude Code 2.1, with procStart in UTC. --switch-to <id> puts another
 * session in that file, like /clear or /resume inside the chat.
 *
 * Built by test/e2e.sh with -DAPP="fx" (or claude, codex, pi) and -DFAKE_HOME.
 */
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void make_dirs(const char *path) {
  char buf[4096];
  snprintf(buf, sizeof buf, "%s", path);
  for (char *p = buf + 1; *p; p++) {
    if (*p == '/') {
      *p = 0;
      mkdir(buf, 0755);
      *p = '/';
    }
  }
  mkdir(buf, 0755);
}

/* Writes one line to a new file; leaves an existing file alone. */
static void write_new(const char *path, const char *line) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
  if (fd < 0) return;
  if (write(fd, line, strlen(line)) < 0) {
  }
  close(fd);
}

int main(int argc, char **argv) {
  const char *app = APP;
  char id[128] = "", child[128] = "", switch_to[128] = "";
  int write_pid_file = 0;
  time_t started = time(NULL);
  if (!strcmp(app, "pi")) {
    /* Like pi: a chat brought back on --session writes nothing until used,
       and its process title hides the session. */
    for (int i = 1; i < argc; i++) memset(argv[i], ' ', strlen(argv[i]));
    printf("fake pi\n");
    fflush(stdout);
    for (;;) pause();
  }
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--write-pid-file")) {
      write_pid_file = 1;
      continue;
    }
    if (!strcmp(argv[i], "--switch-to") && i + 1 < argc) {
      snprintf(switch_to, sizeof switch_to, "%s", argv[++i]);
      continue;
    }
    if (!strcmp(argv[i], "--child") && i + 1 < argc) {
      snprintf(child, sizeof child, "%s", argv[++i]);
      continue;
    }
    if (!strcmp(argv[i], "--help")) {
      printf("usage: %s [-r, --resume [last|<id>]]\n", app);
      return 0;
    }
    if ((!strcmp(argv[i], "--resume") || !strcmp(argv[i], "-r") || !strcmp(argv[i], "resume")) &&
        i + 1 < argc)
      snprintf(id, sizeof id, "%s", argv[++i]);
  }
  if (!id[0]) {
    if (!strcmp(app, "fx"))
      snprintf(id, sizeof id, "new%d", (int)getpid());
    else
      snprintf(id, sizeof id, "00000000-0000-4000-8000-%012d", (int)getpid());
  }

  char cwd[2048], dir[4096], file[4608];
  if (!getcwd(cwd, sizeof cwd)) return 1;
  int keep_open = 1;
  if (!strcmp(app, "fx")) {
    if (child[0]) {
      /* Like fx running a subagent: it holds the subagent's lock too, and the
         subagent's log names its owner. Opened first, so it is listed first. */
      char cdir[4096], cfile[4608], line[512];
      snprintf(cdir, sizeof cdir, "%s/.fx/sessions/v2/%s", FAKE_HOME, child);
      make_dirs(cdir);
      snprintf(cfile, sizeof cfile, "%s/log.jsonl", cdir);
      snprintf(line, sizeof line, "{\"kind\":\"session_created\",\"id\":\"%s\",\"role\":\"child\",\"parent\":\"%s\"}\n",
               child, id);
      write_new(cfile, line);
      snprintf(cfile, sizeof cfile, "%s/lock", cdir);
      if (open(cfile, O_WRONLY | O_CREAT, 0644) < 0) return 1;
    }
    snprintf(dir, sizeof dir, "%s/.fx/sessions/v2/%s", FAKE_HOME, id);
    snprintf(file, sizeof file, "%s/lock", dir);
  } else if (!strcmp(app, "codex")) {
    snprintf(dir, sizeof dir, "%s/.codex/sessions/2026/11/13", FAKE_HOME);
    snprintf(file, sizeof file, "%s/rollout-2026-11-13T10-00-00-%s.jsonl", dir, id);
  } else {
    char slug[2048];
    snprintf(slug, sizeof slug, "%s", cwd);
    for (char *p = slug; *p; p++)
      if (!isalnum((unsigned char)*p)) *p = '-';
    snprintf(dir, sizeof dir, "%s/.claude/projects/%s", FAKE_HOME, slug);
    snprintf(file, sizeof file, "%s/%s.jsonl", dir, id);
    keep_open = 0;
  }
  make_dirs(dir);
  int fd = open(file, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) {
    perror(file);
    return 1;
  }
  char line[4096];
  int n = snprintf(line, sizeof line,
                   "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%s\",\"cwd\":\"%s\"}}\n", id, cwd);
  if (write(fd, line, (size_t)n) != n) return 1;
  if (!keep_open) close(fd);
  if (!strcmp(app, "claude") && write_pid_file) {
    char sdir[4096], sfile[4608], when[64], body[4096];
    strftime(when, sizeof when, "%a %b %d %H:%M:%S %Y", gmtime(&started));
    snprintf(sdir, sizeof sdir, "%s/.claude/sessions", FAKE_HOME);
    make_dirs(sdir);
    snprintf(sfile, sizeof sfile, "%s/%d.json", sdir, (int)getpid());
    int m = snprintf(body, sizeof body,
                     "{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"%s\",\"procStart\":\"%s\","
                     "\"startedAt\":%lld,\"version\":\"fake\"}\n",
                     (int)getpid(), switch_to[0] ? switch_to : id, cwd, when, (long long)started * 1000);
    int sfd = open(sfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (sfd < 0 || write(sfd, body, (size_t)m) != m) return 1;
    close(sfd);
  }
  printf("fake %s on %s\n", app, id);
  fflush(stdout);
  for (;;) pause();
}
