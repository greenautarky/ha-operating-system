#!/bin/sh
/usr/bin/jq -r '.a | test("x")' f
