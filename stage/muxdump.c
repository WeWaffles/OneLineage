#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dirent.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/if.h>

/* muxdump: per-link mux_id query (S26 Nura diagnostic) */
#define BUF 65536
static int getmuxidx(int fd, int ifindex) {
    struct { struct nlmsghdr nl; struct ifinfomsg ifi; } req;
    memset(&req, 0, sizeof(req));
    req.nl.nlmsg_len = sizeof(req);
    req.nl.nlmsg_type = RTM_GETLINK;
    req.nl.nlmsg_flags = NLM_F_REQUEST;
    req.nl.nlmsg_seq = 2;
    req.ifi.ifi_family = AF_UNSPEC;
    req.ifi.ifi_index = ifindex;
    if (send(fd, &req, sizeof(req), 0) < 0) { perror("send"); return -99; }
    char buf[BUF];
    ssize_t len = recv(fd, buf, BUF, 0);
    if (len < 0) { perror("recv"); return -99; }
    struct nlmsghdr *nh = (struct nlmsghdr *)buf;
    if (nh->nlmsg_type == NLMSG_ERROR) {
        struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nh);
        fprintf(stderr, "nlerr=%d\n", err->error);
        return -99;
    }
    if (nh->nlmsg_type != RTM_NEWLINK) return -99;
    struct ifinfomsg *ifi = (struct ifinfomsg *)NLMSG_DATA(nh);
    struct rtattr *rta = (struct rtattr *)((char *)ifi + sizeof(*ifi));
    int rlen = nh->nlmsg_len - NLMSG_LENGTH(sizeof(*ifi));
    long mux = -1;
    for (; RTA_OK(rta, rlen); rta = RTA_NEXT(rta, rlen)) {
        if (rta->rta_type == IFLA_LINKINFO) {
            struct rtattr *a2 = (struct rtattr *)RTA_DATA(rta);
            int l2 = (int)(rta->rta_len - 4);
            for (; RTA_OK(a2, l2); a2 = RTA_NEXT(a2, l2)) {
                if (a2->rta_type == IFLA_INFO_DATA) {
                    struct rtattr *a3 = (struct rtattr *)RTA_DATA(a2);
                    int l3 = a2->rta_len - 4;
                    for (; RTA_OK(a3, l3); a3 = RTA_NEXT(a3, l3)) {
                        if (a3->rta_type == 1 && a3->rta_len >= 8) /* IFLA_RMNET_MUX_ID */
                            mux = *(unsigned int *)RTA_DATA(a3);
                    }
                }
            }
        }
    }
    (void)ifi;
    return (int)mux;
}

int main(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    DIR *d = opendir("/sys/class/net");
    struct dirent *e;
    char path[256], linebuf[32];
    int idx;
    FILE *f;
    if (!d) { perror("opendir"); return 1; }
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        snprintf(path, sizeof(path), "/sys/class/net/%s/ifindex", e->d_name);
        f = fopen(path, "r");
        if (!f) continue;
        idx = (fgets(linebuf, sizeof(linebuf), f)) ? atoi(linebuf) : 0;
        fclose(f);
        if (!idx) continue;
        int mux = getmuxidx(fd, idx);
        printf("%s: mux_id=%d ifindex=%d\n", e->d_name, mux, idx);
    }
    closedir(d);
    return 0;
}
