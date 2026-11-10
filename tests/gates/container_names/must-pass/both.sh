#!/bin/sh
# addon_ is the BOSv1.5.x name; this is prose in a comment
c=$(docker ps --format '{{.Names}}' | grep -E "^(app|addon)_.*_ga_manager$" | head -1)
x=$(ga_ctr_of ga_manager)
