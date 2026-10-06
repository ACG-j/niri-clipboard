/* clip-multi: an X11 CLIPBOARD owner that advertises several targets at once.
 *
 * Usage: clip-multi
 *   Owns CLIPBOARD with: TARGETS, TIMESTAMP, UTF8_STRING, STRING,
 *                        text/plain, text/plain;charset=utf-8, text/html
 *   Prints "READY <winid>" on stdout once ownership is taken.
 *   Prints "REQ <target-name>" for every successful conversion.
 *   Exits on SIGTERM/SIGINT.
 *
 * Purpose: verify that an X11<->Wayland bridge preserves *all* targets,
 * not just a single "best" one. xclip cannot do this.
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

#define PLAIN "multi-plain-PLAIN"
#define HTML  "<b>multi-html-HTML</b>"

static Display *dpy;
static Window win;
static Atom sel, targets, timestamp_a, utf8, string_a, textp, textpu, texthtml;

static void send_data(XSelectionRequestEvent *r, Atom property, Atom type,
                      const void *data, int nbytes)
{
    XChangeProperty(dpy, r->requestor, property, type, 8, PropModeReplace,
                    (const unsigned char *)data, nbytes);
}

static void handle(XSelectionRequestEvent *r)
{
    XSelectionEvent ev;
    memset(&ev, 0, sizeof ev);
    ev.type = SelectionNotify;
    ev.display = r->display;
    ev.requestor = r->requestor;
    ev.selection = r->selection;
    ev.target = r->target;
    ev.time = r->time;
    ev.property = None;

    char *tname = XGetAtomName(dpy, r->target);
    if (r->property == None)
        r->property = r->target;

    if (r->target == targets) {
        Atom list[] = { targets, timestamp_a, utf8, string_a,
                        textp, textpu, texthtml };
        XChangeProperty(dpy, r->requestor, r->property, XA_ATOM, 32,
                        PropModeReplace, (unsigned char *)list,
                        (int)(sizeof list / sizeof list[0]));
        ev.property = r->property;
    } else if (r->target == texthtml) {
        send_data(r, r->property, texthtml, HTML, (int)strlen(HTML));
        ev.property = r->property;
    } else if (r->target == textp || r->target == textpu ||
               r->target == utf8 || r->target == string_a) {
        send_data(r, r->property, r->target, PLAIN, (int)strlen(PLAIN));
        ev.property = r->property;
    } else if (r->target == timestamp_a) {
        unsigned long ts = (unsigned long)r->time;
        XChangeProperty(dpy, r->requestor, r->property, XA_INTEGER, 32,
                        PropModeReplace, (unsigned char *)&ts, 1);
        ev.property = r->property;
    } else {
        ev.property = None; /* refuse */
    }

    if (tname) {
        printf("REQ %s -> %s\n", tname, ev.property == None ? "REFUSED" : "ok");
        fflush(stdout);
        XFree(tname);
    }
    XSendEvent(dpy, r->requestor, False, 0, (XEvent *)&ev);
    XFlush(dpy);
}

static void bye(int s) { (void)s; if (dpy) XCloseDisplay(dpy); _exit(0); }

int main(void)
{
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    signal(SIGPIPE, SIG_IGN);

    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "clip-multi: cannot open display\n"); return 1; }

    int scr = DefaultScreen(dpy);
    win = XCreateSimpleWindow(dpy, RootWindow(dpy, scr), 0, 0, 1, 1, 0, 0, 0);

    sel       = XInternAtom(dpy, "CLIPBOARD", False);
    targets   = XInternAtom(dpy, "TARGETS", False);
    timestamp_a = XInternAtom(dpy, "TIMESTAMP", False);
    utf8      = XInternAtom(dpy, "UTF8_STRING", False);
    string_a  = XInternAtom(dpy, "STRING", False);
    textp     = XInternAtom(dpy, "text/plain", False);
    textpu    = XInternAtom(dpy, "text/plain;charset=utf-8", False);
    texthtml  = XInternAtom(dpy, "text/html", False);

    XSetSelectionOwner(dpy, sel, win, CurrentTime);
    XFlush(dpy);
    if (XGetSelectionOwner(dpy, sel) != win) {
        fprintf(stderr, "clip-multi: failed to own CLIPBOARD\n");
        return 1;
    }
    printf("READY 0x%lx\n", (unsigned long)win);
    fflush(stdout);

    for (;;) {
        XEvent e;
        XNextEvent(dpy, &e);
        if (e.type == SelectionRequest)
            handle(&e.xselectionrequest);
        else if (e.type == SelectionClear)
            break;
    }
    return 0;
}
