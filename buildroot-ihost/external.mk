include $(sort $(wildcard $(BR2_EXTERNAL_IHOST_PATH)/package/*/*.mk))
# Add-on images pre-baked into the data partition (GA patch 0131 reads this;
# upstream HAOS's hassio.mk defines it empty, so "=" and not "?="). The pin
# file lives in the GA layer, where the pin gates read it too
# (scripts/lib/tree-paths.sh GA_ADDON_PINS_ihost). A make command-line value
# still wins.
HASSIO_ADDON_IMAGES_JSON = $(BR2_EXTERNAL_GA_HAOS_PATH)/package/hassio/addon-images.json
