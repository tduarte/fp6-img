#!/usr/bin/env python3
"""Generate drivers/media/i2c/s5kkd1.c from the in-tree s5kjn1.c skeleton and
the register tables decoded from the stock FP6 sensormodule file."""
import json, re, sys
src, tables_json, out = sys.argv[1:4]
t = json.load(open(tables_json))['tables']
modes_tbl, init_tbl = t[:6], t[7]
s = open(src).read()

def seq(regs, indent='\t'):
    return ''.join('%s{ CCI_REG16(0x%04x), 0x%04x },\n' % (indent, r['addr'], r['val']) for r in regs)

# --- split the init table at the two 10 ms delays
parts, cur = [], []
for r in init_tbl['regs']:
    cur.append(r)
    if r['delay_us']:
        parts.append((cur, r['delay_us'])); cur = []
parts.append((cur, 0))
assert len(parts) == 3, len(parts)

# --- cut out the template's tables and mode list
a = s.index('static const struct cci_reg_sequence init_array_setting[] = {')
b = s.index('static int s5kjn1_set_ctrl(')
MODES = [  # (table index, name, default exposure)
    (1, '3104x2336_30fps'),
    (0, '6208x4672_15fps'),
    (4, '1920x1080_120fps'),
]
def reg(tbl, addr):
    return [r['val'] for r in tbl['regs'] if r['addr'] == addr][0]
body = ''
for i, (regs, delay) in enumerate(parts):
    body += 'static const struct cci_reg_sequence s5kkd1_init_%d[] = {\n%s};\n\n' % (i, seq(regs))
for idx, name in MODES:
    body += 'static const struct cci_reg_sequence s5kkd1_%s_mode[] = {\n%s};\n\n' % (name, seq(modes_tbl[idx]['regs']))
body += 'static const struct s5kjn1_mode s5kjn1_supported_modes[] = {\n'
for idx, name in MODES:
    m = modes_tbl[idx]
    w, h, hts, vts = reg(m, 0x34c), reg(m, 0x34e), reg(m, 0x342), reg(m, 0x340)
    body += ('\t{\n\t\t.width = %d,\n\t\t.height = %d,\n\t\t.hts = %d,\n\t\t.vts = %d,\n'
             '\t\t.exposure = %d,\n\t\t.exposure_margin = 24,\n\t\t.reg_list = {\n'
             '\t\t\t.regs = s5kkd1_%s_mode,\n\t\t\t.num_regs = ARRAY_SIZE(s5kkd1_%s_mode),\n\t\t},\n\t},\n'
             % (w, h, hts, vts, vts - 24, name, name))
body += '};\n\n'
s = s[:a] + body + s[b:]

# --- start-streaming sequence: vendor init in three chunks with its delays
a = s.index('\t/* Page pointer */')
b = s.index('\tcci_multi_reg_write(s5kjn1->regmap, reg_list->regs,')
s = s[:a] + '''	/* Init sequence from the vendor settings, including its two delays */
	cci_multi_reg_write(s5kjn1->regmap, s5kkd1_init_0,
			    ARRAY_SIZE(s5kkd1_init_0), &ret);
	if (ret)
		goto error;

	usleep_range(10 * USEC_PER_MSEC, 11 * USEC_PER_MSEC);

	cci_multi_reg_write(s5kjn1->regmap, s5kkd1_init_1,
			    ARRAY_SIZE(s5kkd1_init_1), &ret);
	if (ret)
		goto error;

	usleep_range(10 * USEC_PER_MSEC, 11 * USEC_PER_MSEC);

	cci_multi_reg_write(s5kjn1->regmap, s5kkd1_init_2,
			    ARRAY_SIZE(s5kkd1_init_2), &ret);
''' + s[b:]

# --- constants
def sub1(a, b):
    global s
    assert s.count(a) == 1, (a, s.count(a))
    s = s.replace(a, b)
sub1('// Copyright (c) 2025 Linaro Ltd\n',
     '// Samsung S5KKD1 (S5KKD1SP) 32 MP image sensor driver\n//\n'
     '// Based on the S5KJN1 driver, Copyright (c) 2025 Linaro Ltd.\n'
     '// Register settings taken from the Fairphone (Gen. 6) vendor sensor\n// configuration.\n')
sub1('#define S5KJN1_LINK_FREQ_700MHZ\t\t(700ULL * HZ_PER_MHZ)', '#define S5KJN1_LINK_FREQ_906MHZ\t\t(906ULL * HZ_PER_MHZ)\n'
     '/* VT pixel clock 140 MHz, four pixels per clock */\n#define S5KJN1_PIXEL_RATE\t\t(560ULL * HZ_PER_MHZ)')
s = s.replace('S5KJN1_LINK_FREQ_700MHZ', 'S5KJN1_LINK_FREQ_906MHZ')
sub1('#define S5KJN1_CHIP_ID\t\t\t0x38e1', '#define S5KJN1_CHIP_ID\t\t\t0x4841')
# analogue gain: raw register code, 32 = 1x
sub1('#define S5KJN1_AGAIN_MIN\t\t1\n#define S5KJN1_AGAIN_MAX\t\t64\n#define S5KJN1_AGAIN_STEP\t\t1\n#define S5KJN1_AGAIN_DEFAULT\t\t6\n#define S5KJN1_AGAIN_SHIFT\t\t5',
     '/* Gain register code, 32 is 1x */\n#define S5KJN1_AGAIN_MIN\t\t32\n#define S5KJN1_AGAIN_MAX\t\t512\n#define S5KJN1_AGAIN_STEP\t\t1\n#define S5KJN1_AGAIN_DEFAULT\t\t32')
sub1('ctrl->val << S5KJN1_AGAIN_SHIFT, NULL);', 'ctrl->val, NULL);')
sub1('\tpixel_rate = s5kjn1_freq_to_pixel_rate(s5kjn1_link_freq_menu[0]);', '\tpixel_rate = S5KJN1_PIXEL_RATE;')
a = s.index('static inline u64 s5kjn1_freq_to_pixel_rate'); b = s.index('static int s5kjn1_init_controls')
s = s[:a] + s[b:]
sub1('\t\tsel->r.height = s5kjn1->mode->width;', '\t\tsel->r.height = s5kjn1->mode->height;')
s = s.replace('s5kjn1', 's5kkd1').replace('S5KJN1', 'S5KKD1')
open(out, 'w').write(s)
print('wrote', out, len(s.splitlines()), 'lines')
