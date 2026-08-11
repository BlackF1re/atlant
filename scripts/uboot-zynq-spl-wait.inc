#if defined(CONFIG_XPL_BUILD)
/* AtlANTian: SPL NAND must never depend on the SPL timer becoming usable. */
static int atln_spl_io_error;

static void atln_spl_short_delay(void)
{
	volatile unsigned int i;

	for (i = 0; i < 2048; i++)
		__asm__ __volatile__("nop");
}

static int atln_spl_wait_ready(struct mtd_info *mtd)
{
	struct nand_chip *chip = mtd_to_nand(mtd);
	struct nand_drv *smc = nand_get_controller_data(chip);
	unsigned int polls = 10000000;

	while (polls--) {
		u32 csr = readl(&smc->reg->csr);

		if (csr & ZYNQ_MEMC_SR_RAW_INT_ST1) {
			writel(ZYNQ_MEMC_SR_INT_ST1, &smc->reg->cfr);
			return 0;
		}
	}

	atln_spl_io_error = -ETIMEDOUT;
	printf("AtlANTian SPL NAND: ready timeout\n");
	return -ETIMEDOUT;
}
#endif
