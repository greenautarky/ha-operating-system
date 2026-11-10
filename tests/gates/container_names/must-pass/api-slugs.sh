#!/bin/sh
curl http://supervisor/addons/99f1cad4_ga_manager/info; addon_update=1; ha addons restart 99f1cad4_ga_manager; addon_store_raw_url=x
