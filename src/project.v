module tt_um_im2col_tm (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    localparam IMG_H       = 6;
    localparam IMG_W       = 6;
    localparam K           = 3;
    localparam DW          = 8;
    localparam ACC_W       = 20;
    localparam NUM_MACS    = 4;
    localparam FMAP_N      = IMG_H*IMG_W;   // 36 feature map words
    localparam KERN_N      = K*K;           //  9 kernel words
    localparam FMAP_ADDR_W = 6;             // $clog2(IMG_H*IMG_W)
    localparam OUT_ADDR_W  = 4;             // $clog2(OUT_H*OUT_W)

    wire mode = uio_in[7];

    wire [5:0] addr    = uio_in[5:0];
    wire       ld_pin  = uio_in[6];
    wire       is_kern = (addr >= 6'd36);
    wire       in_range = (addr < 6'd45);

    wire                   ld_en   = ~mode & ld_pin & in_range;
    wire                   ld_sel  = is_kern;
    wire [FMAP_ADDR_W-1:0] ld_addr = is_kern ? (addr - 6'd36) : addr;

    wire [OUT_ADDR_W-1:0] rd_addr = ui_in[3:0];
    wire                  half    = ui_in[4];
    wire                  start   = mode & ui_in[5];

    wire signed [ACC_W-1:0] rd_data;
    wire                    done;

    im2col #(
        .IMG_H (IMG_H),
        .IMG_W (IMG_W),
        .K     (K),
        .DW    (DW),
        .ACC_W (ACC_W),
        .NUM_MACS(NUM_MACS),
        .RD_W  (ACC_W)          // no point sign-extending to 32 off-chip
    ) core (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .done      (done),
        .ld_en     (ld_en),
        .ld_sel_ab (ld_sel),
        .ld_addr   (ld_addr),
        .ld_data   (ui_in),
        .rd_en     (mode),
        .rd_addr   (rd_addr),
        .rd_data   (rd_data)
    );

    // ---- result bus --------------------------------------------------
    assign uo_out  = half ? rd_data[17:10] : rd_data[7:0];
    assign uio_out = {5'b00000, done, half ? rd_data[19:18] : rd_data[9:8]};

    // uio flips direction with mode: inputs while loading, three outputs
    // while reading. uio[7] stays an input in both phases so mode is
    // always drivable.
    assign uio_oe = mode ? 8'b0000_0111 : 8'b0000_0000;

    wire _unused = &{ena, 1'b0};

endmodule
`default_nettype wire

module im2col #(
    parameter IMG_H = 6, //image height
    parameter IMG_W = 6, //image width
    parameter K = 3, //kernel side (square)
    parameter DW = 8, //data width (INT8, signed)
    parameter ACC_W = 20,
    parameter NUM_MACS = 4, // physical MACs; must divide OUT_H*OUT_W
    parameter OUT_H = IMG_H - K + 1, // output height
    parameter OUT_W = IMG_W - K + 1, // output width
    parameter FMAP_ADDR_W = $clog2(IMG_H*IMG_W), // feature map address wdith
    parameter COL_ADDR_W = $clog2((K*K)*(OUT_H*OUT_W)), // "flattened matrix" address size
    parameter TAP_W = $clog2(K*K), // tap index width
    parameter RD_W = 32
)(
    input logic clk,
    input logic rst_n,
    input logic start, // pulse 1 cycle: begin a new multiply
    output logic done, // pulses 1 cycle: full output valid
    input logic ld_en,
    input logic ld_sel_ab, // 0 = write fmap, 1 = write kernel
    input logic [$clog2(IMG_H*IMG_W)-1:0] ld_addr,
    input logic signed [DW-1:0] ld_data,
    input logic rd_en,
    input logic [$clog2(OUT_H*OUT_W)-1:0] rd_addr,
    output logic signed [RD_W-1:0] rd_data
);
    localparam int LANES  = OUT_H*OUT_W;
    localparam int GROUPS = LANES/NUM_MACS;
    localparam int GRP_W  = (GROUPS == 1) ? 1 : $clog2(GROUPS);

    //loading procedure
    logic kernel_write, fmap_write;
    assign kernel_write = (ld_en && ld_sel_ab);
    assign fmap_write = (ld_en && (!ld_sel_ab));

    logic [GRP_W-1:0] group;
    logic signed [DW-1:0] kernel_weight;
    logic [TAP_W-1:0] tap_addr;
    logic [NUM_MACS*DW-1:0] col_data;

    matcol #(
        .IMG_H(IMG_H),
        .IMG_W(IMG_W),
        .K(K),
        .DW(DW),
        .NUM_MACS(NUM_MACS),
        .GRP_W(GRP_W)
    ) fmap_store (
        .rst_n(rst_n),
        .clk(clk),
        .waddr(ld_addr),
        .wdata(ld_data),
        .w_en(fmap_write),
        .tap_addr(tap_addr),
        .group(group),
        .col_data(col_data)
    );

    //kernel memory
    logic [DW-1:0] kernel_memory [(K*K)-1:0];
    always @(posedge clk) begin
        if (kernel_write) begin
            kernel_memory[ld_addr] <= ld_data;
        end
    end
    assign kernel_weight = kernel_memory[tap_addr];

    //mac unit instantiation
    logic valid_in;
    logic signed [ACC_W-1:0] result [(OUT_W*OUT_H)-1:0];
    logic valid_out;
    logic clear_acc;

    logic signed [ACC_W-1:0] acc_out [0:NUM_MACS-1];
    logic mac_valid_out [0:NUM_MACS-1];

    generate
        for (genvar m = 0; m < NUM_MACS; m++) begin : g_mac
            mac_unit #(
                .DW(DW),
                .ACC_W(ACC_W)
            ) u_mac (
                .a(kernel_weight),
                .b($signed(col_data[m*DW +: DW])),
                .valid_in(valid_in),
                .clear_acc(clear_acc),
                .rst_n(rst_n),
                .clk(clk),
                .acc(acc_out[m]),
                .valid_out(mac_valid_out[m])
            );
        end
    endgenerate

    assign valid_out = mac_valid_out[0];

    // tap incrementer and control
    logic running;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0;
            tap_addr <= '0;
            group <= '0;
        end else begin
            if (!running) begin
                if (start) begin
                    running <= 1'b1;
                    tap_addr <= '0;
                    group <= '0;
                end
            end else if (tap_addr == (K*K)-1) begin
                tap_addr <= '0;
                if (group == GRP_W'(GROUPS-1)) begin
                    group <= '0;
                    running <= 1'b0;
                end else begin
                    group <= group + 1'b1;
                end
            end else begin
                tap_addr <= tap_addr + 1'b1;
            end
        end
    end

    assign valid_in = running;
    assign clear_acc = running && (tap_addr == '0);

    logic last_term, last_term_d1, last_term_d2;
    logic [GRP_W-1:0] group_d1, group_d2;

    assign last_term = running && (tap_addr == (K*K)-1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_term_d1 <= 1'b0;
            last_term_d2 <= 1'b0;
            done <= 1'b0;
        end else begin
            last_term_d1 <= last_term;
            last_term_d2 <= last_term_d1;
            done <= last_term_d2 && (group_d2 == GRP_W'(GROUPS-1));
        end
    end

    always @(posedge clk) begin
        group_d1 <= group;
        group_d2 <= group_d1;
    end

    always @(posedge clk) begin
        if (last_term_d2) begin
            for (int p = 0; p < LANES; p++) begin
                if (p/NUM_MACS == int'(group_d2)) begin
                    result[p] <= acc_out[p%NUM_MACS];
                end
            end
        end
    end

    assign rd_data = RD_W'(result[rd_addr]);
endmodule

module matcol #(
    parameter IMG_H, //image height
    parameter IMG_W, //image width
    parameter K, //kernel side (square)
    parameter DW = 8, //data width (INT8, signed)
    parameter NUM_MACS = 4, // lanes read per cycle
    parameter GRP_W = 2, // width of the group index
    parameter OUT_H = IMG_H - K + 1, // output height
    parameter OUT_W = IMG_W - K + 1, // output width
    parameter FMAP_ADDR_W = $clog2(IMG_H*IMG_W), // feature map address wdith
    parameter COL_ADDR_W = $clog2((K*K)*(OUT_H*OUT_W)), // "flattened matrix" address size
    parameter TAP_W = $clog2(K*K) // tap index width
)(
    input rst_n,
    input clk,

    input logic [FMAP_ADDR_W-1:0] waddr,
    input logic signed [DW-1:0] wdata,
    input logic w_en,

    input logic [TAP_W-1:0] tap_addr,
    input logic [GRP_W-1:0] group,

    output logic [NUM_MACS*DW-1:0] col_data
);

    mem #(
        .DEPTH(IMG_H*IMG_W),
        .WIDTH(DW),
        .ADDR_W(FMAP_ADDR_W), // only needs to be as big as feature map itself.
        //this saves space because we don't need to store the flattened matrix.
        .IMG_W(IMG_W),
        .K(K),
        .OUT_W(OUT_W),
        .LANES(OUT_H*OUT_W),
        .NUM_MACS(NUM_MACS),
        .GRP_W(GRP_W)
    ) fmap_storage (
        .clk(clk),
        .rst_n(rst_n),
        .waddr(waddr),
        .wdata(wdata),
        .w_en(w_en),
        .tap_addr(tap_addr),
        .group(group),
        .rdata_flat(col_data)
    );

endmodule

module mem #( // can now store non-square matrices
    parameter DEPTH = 64,
    parameter WIDTH = 8,
    parameter ADDR_W = $clog2(DEPTH),
    parameter IMG_W = 6,
    parameter K = 3,
    parameter OUT_W = 4,
    parameter LANES = 16,
    parameter NUM_MACS = 4,
    parameter GRP_W = 2,
    parameter TAP_W = $clog2(K*K)
) (
    input logic clk,
    input logic rst_n,

    input logic [ADDR_W-1:0] waddr,
    input logic signed [WIDTH-1:0] wdata,
    input logic w_en,

    input logic [TAP_W-1:0] tap_addr,
    input logic [GRP_W-1:0] group,

    // Only the NUM_MACS lanes of the active group, packed low lane first.
    output logic [NUM_MACS*WIDTH-1:0] rdata_flat

);

    logic [WIDTH-1:0] memory [0:DEPTH-1];

    always @(posedge clk) begin
        if (w_en) begin
            memory[waddr] <= wdata;
        end
    end

    logic signed [WIDTH-1:0] window [0:LANES-1][0:(K*K)-1];

    generate
        for (genvar p = 0; p < LANES; p++) begin : g_lane
            for (genvar t = 0; t < K*K; t++) begin : g_tap
                localparam int OH = p / OUT_W;
                localparam int OW = p % OUT_W;
                localparam int KH = t / K;
                localparam int KW = t % K;
                localparam int A = (OH + KH) * IMG_W + (OW + KW);
                assign window[p][t] = memory[A];
            end
        end
    endgenerate

    generate
        for (genvar m = 0; m < NUM_MACS; m++) begin : g_rd
            assign rdata_flat[m*WIDTH +: WIDTH] =
                window[group*NUM_MACS + m][tap_addr];
        end
    endgenerate
endmodule

module mac_unit #(
    parameter DW = 8,
    parameter ACC_W = 32
)(
    input logic signed [DW-1:0] a, b,
    input valid_in,
    input clear_acc,
    input clk,
    input rst_n,

    output logic signed [ACC_W-1:0] acc,
    output reg valid_out
);
    reg valid;
    reg clear;
    reg signed [(2*DW)-1:0] mult;

    //remove rst from this, so that it doesn't check every time it is incremented.
    always @(posedge clk) begin
        mult <= a*b;
    end

    always @(posedge clk) begin
        if (valid) begin
            case (clear)
                1'b1: acc <= mult;
                1'b0: acc <= acc + mult;
            endcase
        end
    end

    // Control registers keep their reset.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 1'b0;
            clear <= 1'b0;
            valid_out <= 1'b0;
        end else begin
            valid <= valid_in;
            clear <= clear_acc;
            valid_out <= valid;
        end
    end

endmodule

//
//   1. rd_en is dropped -- the core never reads it.
//   2. ld_addr and rd_addr share one bus; they are used in different phases.
//   3. ld_sel_ab is decoded from the address instead of costing a pin:
//      addr 0..35 is the feature map, addr 36..44 is the kernel.
//
// The result bus is the part that does not fit (ACC_W=20 plus done needs 21
// output bits, and at most 15 are ever available), so it is read out in two
// 10-bit halves selected by a pin. See the notes at the bottom.
//
//   uio_in[7] = mode:  0 = LOAD, 1 = RUN/READ.  Always an input.
//
//   LOAD (mode = 0), uio_oe = 8'h00, all uio are inputs:
//     ui_in [7:0]  -> ld_data     (signed int8)
//     uio_in[5:0]  -> addr        0..35 feature map, 36..44 kernel
//     uio_in[6]    -> ld_en       write ui_in at addr on this clock edge
//
//   RUN/READ (mode = 1), uio_oe = 8'b0000_0111:
//     ui_in [3:0]  -> rd_addr     which of the 16 outputs
//     ui_in [4]    -> half        0 = bits [9:0], 1 = bits [19:10]
//     ui_in [5]    -> start       hold one clock to launch a convolution
//     uo_out[7:0]  <- result bits [7:0]   or [17:10]
//     uio_out[1:0] <- result bits [9:8]   or [19:18]
//     uio_out[2]   <- done        ONE CLOCK WIDE -- see note below
//
