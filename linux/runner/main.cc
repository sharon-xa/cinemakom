#include <cstdlib>
#include <cstring>

#if defined(__GLIBC__)
#include <malloc.h>
#endif

#include "my_application.h"

// At most 2 glibc arenas (docs/MEMORY.md M2, fix 4). glibc gives each busy
// thread an arena of its own, up to 8 per core, and mpv and FFmpeg run many
// threads: after a 4K video closes, its freed memory stays split over all
// of them, where trimming can't hand it back (findings 6 and 17). Set before
// Flutter starts any thread, so every arena counts. MALLOC_ARENA_MAX (or
// glibc's own tunable) in the environment wins: the memory test sets it to
// compare with glibc's default in one build.
static void LimitMallocArenas() {
#if defined(__GLIBC__)
  if (std::getenv("MALLOC_ARENA_MAX") != nullptr) return;
  const char* tunables = std::getenv("GLIBC_TUNABLES");
  if (tunables != nullptr && std::strstr(tunables, "arena_max") != nullptr) {
    return;
  }
  mallopt(M_ARENA_MAX, 2);
#endif
}

int main(int argc, char** argv) {
  LimitMallocArenas();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
