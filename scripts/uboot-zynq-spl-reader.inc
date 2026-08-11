#if defined(CONFIG_XPL_BUILD)
/*
 * AtlANTian Zynq SPL NAND reader.
 *
 * Do not run the runtime DM/nand_scan_ident path in SPL. BootROM has already
 * configured the Zynq SMC enough to fetch this SPL. The stock NAND contract is
 * fixed and verified by the installer: Micron MT29F2G08ABAEAWP, ID 2c:da, x8,
 * 2 KiB page, 64-byte OOB, 128 KiB eraseblock, Micron on-die ECC.
 */
static struct nand_chip atln_spl_chip;
static struct nand_drv atln_spl_ctrl;
static bool atln_spl_ready;

static int atln_spl_read_oob_marker(u32 page, u8 *marker)
{
	struct mtd_info *mtd = nand_to_mtd(&atln_spl_chip);
	unsigned long addr;
	u8 oob[ATLANTIAN_SPL_NAND_OOB_BYTES];

	atln_spl_io_error = 0;
	atln_spl_chip.cmdfunc(mtd, NAND_CMD_READOOB, 0, page);
	if (atln_spl_io_error)
		return atln_spl_io_error;
	atln_spl_chip.read_buf(mtd, oob, ATLANTIAN_SPL_NAND_OOB_BYTES - 4);
	addr = (unsigned long)atln_spl_chip.IO_ADDR_R | ZYNQ_NAND_CLEAR_CS;
	atln_spl_chip.IO_ADDR_R = (void __iomem *)addr;
	atln_spl_chip.read_buf(mtd, oob + ATLANTIAN_SPL_NAND_OOB_BYTES - 4, 4);
	*marker = oob[ATLANTIAN_SPL_NAND_BAD_BLOCK_POS];
	return 0;
}

static int atln_spl_block_isbad(u32 block)
{
	u32 page = block / ATLANTIAN_SPL_NAND_PAGE_BYTES;
	unsigned int i;

	/* Be conservative: accept a block only if both conventional marker pages are clean. */
	for (i = 0; i < 2; i++) {
		u8 marker;
		int ret = atln_spl_read_oob_marker(page + i, &marker);

		if (ret)
			return ret;
		if (marker != 0xff) {
			printf("AtlANTian SPL NAND: factory-bad block at 0x%08x\n", block);
			return 1;
		}
	}
	return 0;
}

static int atln_spl_read_slice(u32 phys, unsigned int len, u8 *dst)
{
	struct mtd_info *mtd = nand_to_mtd(&atln_spl_chip);
	u32 page = phys / ATLANTIAN_SPL_NAND_PAGE_BYTES;
	u32 column = phys % ATLANTIAN_SPL_NAND_PAGE_BYTES;
	unsigned long addr;

	if (!len || column + len > ATLANTIAN_SPL_NAND_PAGE_BYTES)
		return -EINVAL;
	atln_spl_io_error = 0;
	atln_spl_chip.cmdfunc(mtd, NAND_CMD_READ0, column, page);
	if (atln_spl_io_error)
		return atln_spl_io_error;

	/* Assert CLEAR_CS on the last data access, including short header reads. */
	if (len > 4) {
		atln_spl_chip.read_buf(mtd, dst, len - 4);
		dst += len - 4;
		len = 4;
	}
	addr = (unsigned long)atln_spl_chip.IO_ADDR_R | ZYNQ_NAND_CLEAR_CS;
	atln_spl_chip.IO_ADDR_R = (void __iomem *)addr;
	atln_spl_chip.read_buf(mtd, dst, len);
	return atln_spl_io_error;
}

static int atln_spl_slot_bounds(u32 offs, u32 *base, u32 *end)
{
	const u32 slot = CFG_SYS_NAND_U_BOOT_SIZE;

	if (offs >= CONFIG_SYS_NAND_U_BOOT_OFFS &&
	    offs < CONFIG_SYS_NAND_U_BOOT_OFFS + slot) {
		*base = CONFIG_SYS_NAND_U_BOOT_OFFS;
		*end = CONFIG_SYS_NAND_U_BOOT_OFFS + slot;
		return 0;
	}
#ifdef CONFIG_SYS_NAND_U_BOOT_OFFS_REDUND
	if (offs >= CONFIG_SYS_NAND_U_BOOT_OFFS_REDUND &&
	    offs < CONFIG_SYS_NAND_U_BOOT_OFFS_REDUND + slot) {
		*base = CONFIG_SYS_NAND_U_BOOT_OFFS_REDUND;
		*end = CONFIG_SYS_NAND_U_BOOT_OFFS_REDUND + slot;
		return 0;
	}
#endif
	printf("AtlANTian SPL NAND: read outside U-Boot slots: 0x%08x\n", offs);
	return -EINVAL;
}

/* Translate a logical offset exactly as `nand write` does: bad blocks consume no data. */
static int atln_spl_map_logical(u32 base, u32 end, u32 logical, u32 *phys_out)
{
	u32 phys = base;

	while (logical) {
		int bad;

		if (phys >= end)
			return -ENOSPC;
		bad = atln_spl_block_isbad(phys);
		if (bad < 0)
			return bad;
		if (bad) {
			phys += ATLANTIAN_SPL_NAND_BLOCK_BYTES;
			continue;
		}
		if (logical >= ATLANTIAN_SPL_NAND_BLOCK_BYTES) {
			logical -= ATLANTIAN_SPL_NAND_BLOCK_BYTES;
			phys += ATLANTIAN_SPL_NAND_BLOCK_BYTES;
		} else {
			phys += logical;
			logical = 0;
		}
	}
	*phys_out = phys;
	return 0;
}

int nand_spl_load_image(uint32_t offs, unsigned int size, void *dst)
{
	u32 base, end, phys, logical;
	u8 *out = dst;
	unsigned int done = 0;
	int ret;

	if (!atln_spl_ready)
		return -ENODEV;
	ret = atln_spl_slot_bounds(offs, &base, &end);
	if (ret)
		return ret;
	logical = offs - base;
	if (size > CFG_SYS_NAND_U_BOOT_SIZE - logical)
		return -EFBIG;
	ret = atln_spl_map_logical(base, end, logical, &phys);
	if (ret)
		return ret;

	while (done < size) {
		u32 block = (phys / ATLANTIAN_SPL_NAND_BLOCK_BYTES) * ATLANTIAN_SPL_NAND_BLOCK_BYTES;
		u32 page_left, block_left, slot_left;
		unsigned int chunk = size - done;

		if (phys >= end) {
			printf("AtlANTian SPL NAND: U-Boot slot exhausted by bad blocks\n");
			return -ENOSPC;
		}
		if (phys == block) {
			ret = atln_spl_block_isbad(block);
			if (ret < 0)
				return ret;
			if (ret) {
				phys += ATLANTIAN_SPL_NAND_BLOCK_BYTES;
				continue;
			}
		}
		page_left = ATLANTIAN_SPL_NAND_PAGE_BYTES - phys % ATLANTIAN_SPL_NAND_PAGE_BYTES;
		block_left = ATLANTIAN_SPL_NAND_BLOCK_BYTES - phys % ATLANTIAN_SPL_NAND_BLOCK_BYTES;
		slot_left = end - phys;
		if (chunk > page_left)
			chunk = page_left;
		if (chunk > block_left)
			chunk = block_left;
		if (chunk > slot_left)
			chunk = slot_left;
		if (!chunk)
			return -ENOSPC;
		ret = atln_spl_read_slice(phys, chunk, out + done);
		if (ret) {
			printf("AtlANTian SPL NAND: read failed at 0x%08x: %d\n", phys, ret);
			return ret;
		}
		phys += chunk;
		done += chunk;
	}
	return 0;
}

void nand_deselect(void)
{
}

static int atln_spl_hw_init(void)
{
	struct mtd_info *mtd = nand_to_mtd(&atln_spl_chip);
	u8 maf, dev, i, feature[4];
	u8 enable[4] = { ONDIE_ECC_FEATURE_ENABLE, 0, 0, 0 };
	unsigned long ecc_cfg;
	int ret;

	atln_spl_ctrl.reg = (struct zynq_nand_smc_regs *)ATLANTIAN_SPL_NAND_SMC_BASE;
	atln_spl_ctrl.config.nand_base = (void __iomem *)ATLANTIAN_SPL_NAND_DATA_BASE;
	nand_set_controller_data(&atln_spl_chip, &atln_spl_ctrl);
	atln_spl_chip.IO_ADDR_R = atln_spl_ctrl.config.nand_base;
	atln_spl_chip.IO_ADDR_W = atln_spl_ctrl.config.nand_base;
	atln_spl_chip.cmdfunc = zynq_nand_cmd_function;
	atln_spl_chip.dev_ready = zynq_nand_device_ready;
	atln_spl_chip.select_chip = zynq_nand_select_chip;
	atln_spl_chip.chip_delay = 30;
	atln_spl_chip.read_buf = zynq_nand_read_buf;
	atln_spl_chip.write_buf = zynq_nand_write_buf;
	atln_spl_chip.chipsize = ATLANTIAN_SPL_NAND_TOTAL_BYTES;
	atln_spl_chip.onfi_params.addr_cycles = ATLANTIAN_SPL_NAND_ADDR_CYCLES;
	mtd->writesize = ATLANTIAN_SPL_NAND_PAGE_BYTES;
	mtd->oobsize = ATLANTIAN_SPL_NAND_OOB_BYTES;
	mtd->erasesize = ATLANTIAN_SPL_NAND_BLOCK_BYTES;
	mtd->size = ATLANTIAN_SPL_NAND_TOTAL_BYTES;

	printf("AtlANTian SPL NAND: fixed-geometry init\n");
	atln_spl_io_error = 0;
	ret = zynq_nand_init_nand_flash(mtd, 0);
	if (ret)
		return ret;
	atln_spl_chip.cmdfunc(mtd, NAND_CMD_RESET, -1, -1);
	if (atln_spl_io_error)
		return atln_spl_io_error;
	atln_spl_chip.cmdfunc(mtd, NAND_CMD_READID, 0, -1);
	maf = readb(atln_spl_chip.IO_ADDR_R);
	dev = readb(atln_spl_chip.IO_ADDR_R);
	if (maf != 0x2c || dev != 0xda) {
		printf("AtlANTian SPL NAND: unsupported NAND ID %02x:%02x\n", maf, dev);
		return -ENODEV;
	}

	atln_spl_chip.cmdfunc(mtd, NAND_CMD_SET_FEATURES, ONDIE_ECC_FEATURE_ADDR, -1);
	for (i = 0; i < 4; i++)
		writeb(enable[i], atln_spl_chip.IO_ADDR_W);
	atln_spl_short_delay();
	atln_spl_chip.cmdfunc(mtd, NAND_CMD_GET_FEATURES, ONDIE_ECC_FEATURE_ADDR, -1);
	if (atln_spl_io_error)
		return atln_spl_io_error;
	atln_spl_chip.read_buf(mtd, feature, sizeof(feature));
	if (!(feature[0] & ONDIE_ECC_FEATURE_ENABLE)) {
		printf("AtlANTian SPL NAND: Micron on-die ECC did not enable\n");
		return -EIO;
	}

	ecc_cfg = readl(&atln_spl_ctrl.reg->emcr);
	ecc_cfg &= ~ZYNQ_MEMC_NAND_ECC_MODE_MASK;
	writel(ecc_cfg, &atln_spl_ctrl.reg->emcr);
	printf("AtlANTian SPL NAND: Micron 2c:da on-die ECC ready\n");
	return 0;
}

void board_nand_init(void)
{
	struct mtd_info *mtd = nand_to_mtd(&atln_spl_chip);
	int ret = atln_spl_hw_init();

	if (ret) {
		printf("AtlANTian SPL NAND: init failed: %d\n", ret);
		return;
	}
	ret = nand_register(0, mtd);
	if (ret) {
		printf("AtlANTian SPL NAND: MTD registration failed: %d\n", ret);
		return;
	}
	atln_spl_ready = true;
}
#else
void board_nand_init(void)
{
	struct udevice *dev;
	int ret;

	ret = uclass_get_device_by_driver(UCLASS_MTD,
					  DM_DRIVER_GET(zynq_nand), &dev);
	if (ret && ret != -ENODEV)
		pr_err("Failed to initialize %s. (error %d)\n", dev->name, ret);
}
#endif
