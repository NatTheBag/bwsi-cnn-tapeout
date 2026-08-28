<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->
![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# 6x6 CNN Accelerator 

The purpose of this project is to create an ASIC that computes convolutions for a 6x6 input image and a 3x3 kernel. This repository contains the GDS file required to tapeout this chip, as well as the source files and testbenches used to create it. We acknowledge the MIT BeaverWorks Summer Institute for their guidance and creation of this opportunity. 

Project Contributors: Tori Porat, Han Lu, Sharada Parameswaran, Michael Evans

## Architecture
The primary I/O are the loaded matrices and the computed matrix respectively. 

The loading procedure is as follows: First, the memory bank is selected using a binary selector, with writing `0` selecting the feature map, while writing `1` selects the kernel to be written. Then, `ld_addr` selects the address within the memory bank to write to. Finally, an 8 bit `ld_data` corresponding to the data in that address is loaded. Loading for both the kernel and the feature map completes the loading process. The reading process is simple, with a `rd_addr` to specify matrix element and a 32 bit integer output via `rd_data`.

The convolution computation comprises of 2 main parts: (1) flattening the matrix into column form for use in im2col and (2) using parallel MAC (multiply and accumulate) units to compute the dot products necessary for each shifted frame in the convolution. To achieve step 1, the memory bank was modified to manipulate the address from the transformed matrix into the corresponding address for the original feature map. This way, the MAC units believe that they are accessing an intermediate column matrix, while in reality they are still accessing the matrix that was loaded, thus saving space. Multiply and accumulate units are then instantiated, accessing these memory banks. For this 6x6 case, we elected to use 4 MAC units which balances space and efficiency. An FSM controls the current frame being computed, hence coordinating data flow. 

Optimizations: 
1. Rather than using combinational circuitry to calculate the addresses of the transformed matrix, we calculated them pre-computationally and hard-wired them on the circuit, since the addresses are constant sequentially. 
2. Memory bank multiporting to allow for parallel MAC computation
3. Data resizing to reduce space, eliminating unneeded allocation.

Our Final Power Distribution:
<img width="499" height="254" alt="Final CNN ASIC Power Distribution" src="https://github.com/user-attachments/assets/cd6e8073-8c29-4958-bbd6-1dd44e38d02f" />

## Testbench
We decided to create two testbenches in order to facilitate debugging our Verilog code. We started with our smaller Matcol Module and primarily focused on verifying the correct tap address. This way, we can ensure that the correct calculations are being performed. Our overall CNN testbench includes loading the test images and kernels, checking all 16 cases using MAC multiplication (for a total of 144 outputs), and comparing each output to the expected feature map. Despite some issues here and there, we were able to create a testbench where all cases passed, increasing our confidence that the Verilog to GDSII flow would work properly. 

<img width="526" height="384" alt="Passed Testbench" src="https://github.com/user-attachments/assets/4c20b0a9-614f-41b0-954d-9601dcc59b75" />

Fun Fact! Single-layer CNNs can perform edge detection using Sobel Filters. To fully test our code, we wrote another testbench where we fed in a 16x16 image of a bunny (of course), and received an 14x14 output of the edges. This can be seen below. 

<img width="403" height="311" alt="Bunny Image" src="https://github.com/user-attachments/assets/e4952c9b-d7ed-4a6c-b4ad-a5d4ac9e8442" />
<img width="628" height="281" alt="Bunny edges" src="https://github.com/user-attachments/assets/5cfb77aa-b3cc-4064-be3b-596516266c49" />

## Outputs
After running our Verilog through OpenLane and completing extra optimizations, we were able to eliminate all antenna errors, as well as pass DRC and LVS Checks. 

<img width="838" height="248" alt="Checks passed" src="https://github.com/user-attachments/assets/887d5b07-1ac8-4cbf-8ced-ea526835f07e" />

This meant that our ASIC was finally done, and below are some views of the GDSII file in KLayout and the Tiny Tapeout viewer (https://gds-viewer.tinytapeout.com/) respectively. 

<img width="691" height="638" alt="KLayout ASIC View" src="https://github.com/user-attachments/assets/120ffc62-c668-440c-bda9-f86f9fbd5b6b" />

<img width="308" height="310" alt="Tiny Tapeout View 1" src="https://github.com/user-attachments/assets/619fa427-e260-4de8-9a87-f62aee23cdbc" />
<img width="541" height="529" alt="Tiny Tapeout View 2" src="https://github.com/user-attachments/assets/a4030e4d-9797-4853-8903-0acfdedbd6ab" />

