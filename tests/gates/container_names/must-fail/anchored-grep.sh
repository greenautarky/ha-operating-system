#!/bin/sh
c=$(docker ps --format '{{.Names}}' | grep -E "^addon_.*_ga_manager$" | head -1)
