#!/bin/sh
docker ps --format "{{.Names}}" | grep addon_$slug
