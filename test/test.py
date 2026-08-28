# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# Parameters
IMG_H = 6
IMG_W = 6
K = 3
DW = 8
ACC_W = 32

OUT_H = IMG_H - K + 1
OUT_W = IMG_W - K + 1


def to_twos_complement(value, width):
    if value < 0:
        value += 1 << width
    return value


def from_twos_complement(value, width):
    if value & (1 << (width - 1)):
        value -= 1 << width
    return value


def compute_golden(fmap, kernel):
    expected = [
        [0 for _ in range(OUT_W)]
        for _ in range(OUT_H)
    ]
    for i in range(OUT_H):
        for x in range(OUT_W):

            for r in range(K):
                for c in range(K):
                    expected[i][x] += (
                        fmap[i + r][x + c] *
                        kernel[r][c]
                    )
    return expected


async def load_fmap(dut, fmap):

    dut._log.info("Loading feature map")

    # 0 = feature map
    dut.ld_sel_ab.value = 0

    for r in range(IMG_H):
        for c in range(IMG_W):
            dut.ld_en.value = 1
            dut.ld_addr.value = r * IMG_W + c
            dut.ld_data.value = to_twos_complement(
                fmap[r][c],
                DW
            )

            await ClockCycles(dut.clk, 1)

    dut.ld_en.value = 0


async def load_kernel(dut, kernel):
    dut._log.info("Loading kernel")

    # 1 = kernel
    dut.ld_sel_ab.value = 1

    for r in range(K):
        for c in range(K):

            dut.ld_en.value = 1
            dut.ld_addr.value = r * K + c
            dut.ld_data.value = to_twos_complement(
                kernel[r][c],
                DW
            )

            await ClockCycles(dut.clk, 1)

    dut.ld_en.value = 0


@cocotb.test()
async def test_matcol(dut):

    dut._log.info("Start")

    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.rst_n.value = 0
    dut.start.value = 0
    dut.ld_en.value = 0
    dut.ld_sel_ab.value = 0
    dut.ld_addr.value = 0
    dut.ld_data.value = 0
    dut.rd_en.value = 0
    dut.rd_addr.value = 0

    fmap = [
        [r + c for c in range(IMG_W)]
        for r in range(IMG_H)
    ]

    kernel = [
        [1 for c in range(K)]
        for r in range(K)
    ]


    expected = compute_golden(fmap, kernel)

    # Print expected output
    dut._log.info("Expected output:")
    for row in expected:
        dut._log.info(str(row))
    dut._log.info("Reset")
    await ClockCycles(dut.clk, 2)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)
    await load_fmap(dut, fmap)
    await load_kernel(dut, kernel)
    dut._log.info("Starting computation")
    dut.start.value = 1
    await ClockCycles(dut.clk, 1)
    dut.start.value = 0
    dut._log.info("Waiting for done")
    while dut.done.value == 0:
        await ClockCycles(dut.clk, 1)
    dut._log.info("Calculation complete")
    dut._log.info("Checking results")
    
    passed = 0
    failed = 0

    for i in range(OUT_H):
        for x in range(OUT_W):
            p_idx = i * OUT_W + x
            dut.rd_en.value = 1
            dut.rd_addr.value = p_idx

            await ClockCycles(dut.clk, 1)
            actual = from_twos_complement(
                int(dut.rd_data.value),
                ACC_W
            )
            expected_value = expected[i][x]
            if actual != expected_value:
                dut._log.error(
                    f"FAIL [{i}][{x}] "
                    f"address={p_idx} "
                    f"expected={expected_value} "
                    f"got={actual}"
                )
                failed += 1
            else:
                dut._log.info(
                    f"PASS [{i}][{x}] = {actual}"
                )
                passed += 1

    dut.rd_en.value = 0
    dut._log.info(
        f"Results: {passed} passed, {failed} failed"
    )
    assert failed == 0
    dut._log.info("ALL TESTS PASSED")
