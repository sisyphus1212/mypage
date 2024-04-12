```c
static __rte_always_inline void
vhost_log_page(uint8_t *log_base, uint64_t page)
{
	vhost_set_bit(page % 8, &log_base[page / 8]);
}
```