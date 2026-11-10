#!/bin/sh
c=$(docker ps --format "{{.Names}}" | grep -E "^(app|addon)_.*_ga_manager$" | head -1)
