# Top Testbench

register_tb(
    NAME tb_top_npl
    TB tb_top_npl.sv

    RTL_MODULES
        top_npl

        wb_intercon

        alu
        fpu

        i_regfile
        f_regfile
        csr_regfile
        prog_counter
        ins_decoder

        d_mem
        i_mem

        hazard_unit
        trap_ctrl

        clk_ctrl
        gpio
        irq_ctrl
        uart0


)