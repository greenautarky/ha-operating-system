include $(sort $(wildcard $(BR2_EXTERNAL_DSGW210_PATH)/package/*/*.mk))

# --- Data-partition bake (GA layer, patch 0131) -----------------------------
# The GA channel names ghcr.io/greenautarky/{arch}-hassio-* for the Supervisor
# and every plugin, and the armv7-only ghcr.io/greenautarky/home-assistant-armv7
# for Core. None of them is published for aarch64 yet, and there is no upstream
# substitute (an upstream Supervisor polls version.home-assistant.io, which
# would take the device out of GA's channel control). So this board bakes NONE
# of them, loudly; the launcher (patch 0130) pulls the Supervisor from the GA
# channel once it is published and fails closed (error in the journal) until
# then.
# Remove this line when the aarch64 GA images exist.
GA_HASSIO_SKIP_IMAGES = supervisor dns audio cli multicast observer core
# No add-on list for this board yet: which add-ons it runs, and their aarch64
# pins, are open product decisions.
