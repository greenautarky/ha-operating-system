# Onboarding Reset

Reset GA onboarding state on a deployed device so a new tenant can go through
the setup wizard. Stock HA onboarding and the admin user are not affected —
only the GA-specific onboarding panel is reset.

## Components

| Component | Location | Repo |
|-----------|----------|------|
| Reset script | `buildroot-external/rootfs-overlay/usr/sbin/ga-reset-onboarding` | ha-operating-system |
| GA onboarding panel | `homeassistant/components/greenautarky_onboarding/` | homeassisant_core |

## How it works

The GA onboarding state lives in a single file:
```
/mnt/data/supervisor/homeassistant/.storage/greenautarky_onboarding
```

Resetting onboarding = writing this file with `completed: false` and `tenant_mode: true`.
The GA panel detects this on next page load and shows the tenant setup wizard.

Stock HA onboarding stays done. The admin user stays intact. The GA panel
handles tenant user creation itself.

### Reset script (`ga-reset-onboarding`)

Deployed in the OS via rootfs-overlay into `/usr/sbin/` (on `$PATH`).

```
Usage: ga-reset-onboarding [--dry-run]

Options:
  --dry-run   Show what would be done without making changes
```

All it does is write/overwrite the `greenautarky_onboarding` storage file:
```json
{
    "version": 1,
    "key": "greenautarky_onboarding",
    "data": {
        "completed": false,
        "tenant_mode": true,
        "gdpr_accepted": false,
        "steps_done": []
    }
}
```

No need to stop HA Core, no auth file manipulation, no Python-in-Docker.

## Full device lifecycle

```
PROVISIONING (ga-flasher-py)
  stage 50  →  admin created
  stage 69  →  greenautarky_onboarding written (completed=false, tenant_mode=true)
                  ↓
FIRST TENANT ONBOARDING
  GA panel appears → GDPR consent, user account, custom pages, analytics
  Panel sets completed=true when done
                  ↓
DEVICE IN USE
  tenant uses HA normally
                  ↓
RESET FOR NEW TENANT
  SSH to device:  ga-reset-onboarding
  (or inline in flasher: write greenautarky_onboarding file)
                  ↓
NEW TENANT ONBOARDING
  GA panel appears again → same flow as first tenant
```

## Testing

### Dry run

```bash
ssh root@<device-ip> -p 22222
ga-reset-onboarding --dry-run
```

### Full reset

```bash
ga-reset-onboarding
# → GA onboarding panel appears on next browser page load
```

### Inline alternative (no script needed)

```bash
cat > /mnt/data/supervisor/homeassistant/.storage/greenautarky_onboarding << 'EOF'
{
    "version": 1,
    "key": "greenautarky_onboarding",
    "data": {
        "completed": false,
        "tenant_mode": true,
        "gdpr_accepted": false,
        "steps_done": []
    }
}
EOF
```
