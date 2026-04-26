// translate-c chokes on glibc's _FORTIFY_SOURCE open() bits in release mode.
// We do not not rely on the fortify wrappers so we disable them here.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0

#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <unistd.h>
