#!/bin/sh
docker ps --filter name=addon_ --format "{{.Names}}"
