# Host /data trees that host daemons (installd, artd, idmap2d, ...) touch for
# the guest. guest_prepare.sh binds the staged copy over each of them for the
# session, so those daemons never reach One UI's real data; return_to_oneui.sh
# removes the binds again. "host path:staged path", relative to /data and to
# $STAGE/data. Sourced by guest_prepare.sh, return_to_oneui.sh and
# scripts/deploy-phone.sh.
#
# data:user/0 - for user 0, installd's CE app path is /data/data.
# media - shared storage; the guest has its own (run 25 deleted the photos).
# misc/user, misc_{ce,de}/0/{sdksandbox,rollback} - what installd's destroy,
#   reconcile and snapshot calls reach besides the app trees.
# resource-cache - idmap2d writes idmaps and FRROs there.
BRIDGES="app:app app-staging:app-staging user:user user_de:user_de dalvik-cache:dalvik-cache misc/profiles:misc/profiles data:user/0 media:media misc/user:misc/user misc_ce/0/sdksandbox:misc_ce/0/sdksandbox misc_de/0/sdksandbox:misc_de/0/sdksandbox misc_ce/0/rollback:misc_ce/0/rollback misc_de/0/rollback:misc_de/0/rollback resource-cache:resource-cache"
