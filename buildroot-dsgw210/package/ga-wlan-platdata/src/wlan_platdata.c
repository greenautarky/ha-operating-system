// SPDX-License-Identifier: GPL-2.0
/*
 * DSGW-210 OOT WLAN platdata driver
 *
 * Replicates the stock Rockchip BSP `rfkill-wlan` / `wlan-platdata` chip
 * power-on sequence on a 6.18 mainline kernel:
 *
 *   1. Parse DT for WIFI,poweren_gpio, WIFI,vbat_gpio, mmc-host phandle.
 *   2. On probe (after dwmmc1 has already failed initial setup_bus
 *      because the chip wasn't powered):
 *        - drive vbat HIGH (if not already)
 *        - drive poweren HIGH
 *        - wait for chip-stable
 *        - call mmc_detect_change() on the mmc-host to retrigger
 *          mmc_rescan; this time CMD0 succeeds because the chip is on
 *
 * Without this, mainline mmc-core's initial rescan at 400/300/200/100 kHz
 * cascade exhausts before the chip is awake (we use mmc-pwrseq-simple
 * but its post-power-on timing is too tight). Stock BSP does this via
 * a bespoke `rfkill_wlan_probe` + `rockchip_wifi_power(1)` after rp_gpio
 * already boots gpio50 HIGH from u-boot stage.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_gpio.h>
#include <linux/of_platform.h>
#include <linux/gpio/consumer.h>
#include <linux/delay.h>
#include <linux/clk.h>
#include <linux/mmc/host.h>
#include <linux/device.h>
#include <linux/string.h>

extern void mmc_detect_change(struct mmc_host *host, unsigned long delay);
/* The module uses plain mmc_detect_change() to retrigger the rescan. */

struct ga_wlan_platdata {
	struct device *dev;
	struct gpio_desc *poweren;	/* WIFI,poweren_gpio (WL_REG_ON) */
	struct gpio_desc *vbat;		/* WIFI,vbat_gpio    */
	struct clk *ext_clk;		/* 32 kHz LPO        */
	struct mmc_host *mmc_host;	/* SDIO host to rescan */
};

/*
 * device_find_child() match callback: true for the mmc_host class device.
 * The dwmmc platform device registers exactly one such child (mmcN), so
 * matching on the class name is unambiguous and robust — unlike the old
 * code, which ran device_find_child() with a NULL match function (which
 * dereferences NULL in the kernel and oopsed) and then blindly did
 * container_of() over whatever device's name happened to contain "mmc".
 */
static int ga_wlan_is_mmc_host(struct device *dev, const void *data)
{
	return dev->class && dev->class->name &&
	       !strcmp(dev->class->name, "mmc_host");
}

static struct mmc_host *ga_wlan_find_mmc_host(struct device_node *of)
{
	struct platform_device *pdev;
	struct device *mmc_dev;
	struct mmc_host *host;

	/* The "mmc-host" phandle points at the dwmmc platform node. */
	pdev = of_find_device_by_node(of);
	if (!pdev)
		return NULL;

	/* The struct mmc_host's class_dev is registered as a child of it. */
	mmc_dev = device_find_child(&pdev->dev, NULL, ga_wlan_is_mmc_host);
	put_device(&pdev->dev);
	if (!mmc_dev)
		return NULL;

	host = container_of(mmc_dev, struct mmc_host, class_dev);
	put_device(mmc_dev);	/* used transiently; the host stays alive */
	return host;
}

static int ga_wlan_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *of = dev->of_node;
	struct device_node *mmc_of;
	struct ga_wlan_platdata *pd;
	int ret;

	pd = devm_kzalloc(dev, sizeof(*pd), GFP_KERNEL);
	if (!pd)
		return -ENOMEM;

	pd->dev = dev;

	/* gpios from DT */
	pd->vbat = devm_gpiod_get_optional(dev, "WIFI,vbat", GPIOD_OUT_LOW);
	if (IS_ERR(pd->vbat))
		return dev_err_probe(dev, PTR_ERR(pd->vbat),
				     "WIFI,vbat-gpios\n");

	pd->poweren = devm_gpiod_get_optional(dev, "WIFI,poweren", GPIOD_OUT_LOW);
	if (IS_ERR(pd->poweren))
		return dev_err_probe(dev, PTR_ERR(pd->poweren),
				     "WIFI,poweren-gpios\n");

	/* optional 32 kHz LPO clock */
	pd->ext_clk = devm_clk_get_optional(dev, "ext_clock");
	if (IS_ERR(pd->ext_clk))
		return dev_err_probe(dev, PTR_ERR(pd->ext_clk), "ext_clock\n");

	if (pd->ext_clk) {
		ret = clk_prepare_enable(pd->ext_clk);
		if (ret)
			return dev_err_probe(dev, ret, "enable ext_clock\n");
	}

	/*
	 * Power-up sequence (replicates the BSP rockchip_wifi_power(1)):
	 *  - VBAT HIGH (if a gpio is given; usually it's a separate
	 *    always-on regulator and pd->vbat is NULL)
	 *  - clean LOW pulse on WL_REG_ON to guarantee a fresh power-on
	 *    edge (the chip must NOT have been powered for seconds before
	 *    this — see WIFI-RTL8821CS-INVESTIGATION.md: a long-powered
	 *    uninitialised RTL8821CS holds DAT0 low forever, which stalls
	 *    dwmmc's internal CMD_UPD_CLK / PRV_DAT_WAIT)
	 *  - WL_REG_ON HIGH
	 *  - settle (~200 ms — stock uses msleep(100); we give margin)
	 *  - then the caller triggers mmc_detect_change()
	 */
	if (pd->vbat) {
		gpiod_set_value_cansleep(pd->vbat, 1);
		dev_info(dev, "WIFI,vbat HIGH\n");
		msleep(50);
	}
	if (pd->poweren) {
		gpiod_set_value_cansleep(pd->poweren, 0);	/* clean LOW */
		dev_info(dev, "WIFI,poweren LOW (reset edge)\n");
		msleep(50);
		gpiod_set_value_cansleep(pd->poweren, 1);
		dev_info(dev, "WIFI,poweren HIGH\n");
		msleep(200);
	}

	/*
	 * Find the dwmmc platform device via the "mmc-host" DT phandle and
	 * ask it to kick the deferred SDIO rescan. The patched
	 * dw_mmc-rockchip clears the host's rescan_disable flag and calls
	 * mmc_detect_change(). This is the path that mimics the BSP
	 * mmc_host_rescan() + set_sdio_status() flow.
	 *
	 * Fallback for an unpatched kernel: resolve mmc_host directly and
	 * call mmc_detect_change() — works only if rescan_disable was never
	 * set, which is the pre-patch behaviour.
	 */
	mmc_of = of_parse_phandle(of, "mmc-host", 0);
	if (!mmc_of) {
		dev_warn(dev, "no mmc-host phandle, can't trigger rescan\n");
	} else {
		pd->mmc_host = ga_wlan_find_mmc_host(mmc_of);
		of_node_put(mmc_of);
		if (pd->mmc_host) {
			dev_info(dev, "triggering rescan on %s\n",
				 mmc_hostname(pd->mmc_host));
			mmc_detect_change(pd->mmc_host, msecs_to_jiffies(50));
		} else {
			dev_warn(dev, "couldn't resolve mmc-host\n");
		}
	}

	platform_set_drvdata(pdev, pd);
	dev_info(dev, "probe ok\n");
	return 0;
}

static void ga_wlan_remove(struct platform_device *pdev)
{
	struct ga_wlan_platdata *pd = platform_get_drvdata(pdev);

	if (pd->poweren)
		gpiod_set_value_cansleep(pd->poweren, 0);
	if (pd->vbat)
		gpiod_set_value_cansleep(pd->vbat, 0);
	if (pd->ext_clk)
		clk_disable_unprepare(pd->ext_clk);
}

static const struct of_device_id ga_wlan_of_match[] = {
	{ .compatible = "greenautarky,wlan-platdata" },
	{ .compatible = "rockchip,wlan-platdata" },
	{},
};
MODULE_DEVICE_TABLE(of, ga_wlan_of_match);

static struct platform_driver ga_wlan_driver = {
	.probe	= ga_wlan_probe,
	.remove	= ga_wlan_remove,
	.driver	= {
		.name		= "ga-wlan-platdata",
		.of_match_table	= ga_wlan_of_match,
	},
};
module_platform_driver(ga_wlan_driver);

MODULE_AUTHOR("GreenAutarky");
MODULE_DESCRIPTION("WLAN power-on + SDIO rescan trigger (RTL8821CS / RK3328)");
MODULE_LICENSE("GPL");
