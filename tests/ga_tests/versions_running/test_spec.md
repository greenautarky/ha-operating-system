# versions_running

Does the device run what the image pins? VRUN-01 Core, VRUN-02 Supervisor, VRUN-10.. one per pinned add-on, VRUN-90 coverage.
Expectations: expected.<board>.env, generated (scripts/gen-running-versions.py). A pin ahead of the store fails here unless the device was seeded from the bench store; that is intended.
