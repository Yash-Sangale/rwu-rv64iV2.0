# FPU RTL module

register_rtl_module(
    NAME fpu
    FILES
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_add_sub.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_align.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_class.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_cmp.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_ctrl.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_div_sqrt.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_fma.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_mul.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_normalize.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_rounding.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_top.sv



)