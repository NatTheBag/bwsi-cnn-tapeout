# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

IMG_H = 6
IMG_W = 6
K = 3
DW = 8
ACC_W = 20

OUT_H = IMG_H - K + 1
OUT_W = IMG_W - K + 1


def signed_to_unsigned(value, width):
    if value < 0:
        value += 1 << width
    return value


def unsigned_to_signed(value, width):
    if value & (1 << (width - 1)):
        value -= 1 << width
    return value


def compute_golden(fmap, kernel):
    expected = [[0 for _ in range(OUT_W)] for _ in range(OUT_H)]

    for i in range(OUT_H):
        for x in range(OUT_W):
            for r in range(K):
                for c in range(K):
                    expected[i][x] += fmap[i + r][x + c] * kernel[r][c]

    return expected


async def load_value(dut, address, data):
    dut.ui_in.value = signed_to_unsigned(data, DW)
    dut.uio_in.value = (1 << 6) | address
    await ClockCycles(dut.clk, 1)


async def load_fmap(dut, fmap):
    for r in range(IMG_H):
        for c in range(IMG_W):
            await load_value(dut, r * IMG_W + c, fmap[r][c])

    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 1)


async def load_kernel(dut, kernel):
    for r in range(K):
        for c in range(K):
            await load_value(dut, 36 + r * K + c, kernel[r][c])

    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 1)


async def start_convolution(dut):
    dut.uio_in.value = 1 << 7
    dut.ui_in.value = 1 << 5
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value = 0


async def wait_for_done(dut):
    dut.uio_in.value = 1 << 7

    for _ in range(1000):
        if int(dut.uio_out.value) & (1 << 2):
            return
        await ClockCycles(dut.clk, 1)

    assert False, "DUT never asserted done"


async def read_result(dut, address):
    dut.uio_in.value = 1 << 7

    dut.ui_in.value = address
    await ClockCycles(dut.clk, 1)

    low = int(dut.uo_out.value)
    low_upper = int(dut.uio_out.value) & 0x03
    low_10 = low | (low_upper << 8)

    dut.ui_in.value = address | (1 << 4)
    await ClockCycles(dut.clk, 1)

    high = int(dut.uo_out.value)
    high_upper = int(dut.uio_out.value) & 0x03
    high_10 = high | (high_upper << 8)

    result = low_10 | (high_10 << 10)

    return unsigned_to_signed(result, ACC_W)


@cocotb.test()
async def test_matcol(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    await ClockCycles(dut.clk, 10)

    dut.rst_n.value = 1

    await ClockCycles(dut.clk, 2)

    fmap = [[r + c for c in range(IMG_W)] for r in range(IMG_H)]
    kernel = [[1 for _ in range(K)] for _ in range(K)]

    expected = compute_golden(fmap, kernel)

    await load_fmap(dut, fmap)
    await load_kernel(dut, kernel)

    await start_convolution(dut)
    await wait_for_done(dut)

    passed = 0
    failed = 0

    for i in range(OUT_H):
        for x in range(OUT_W):
            address = i * OUT_W + x
            actual = await read_result(dut, address)
            expected_value = expected[i][x]

            if actual != expected_value:
                dut._log.error(
                    f"FAIL [{i}][{x}] address={address} "
                    f"expected={expected_value} got={actual}"
                )
                failed += 1
            else:
                dut._log.info(
                    f"PASS [{i}][{x}] = {actual}"
                )
                passed += 1

    assert failed == 0, f"{failed} test(s) failed"
