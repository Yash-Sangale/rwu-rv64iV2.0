# FPU RTL module

register_rtl_module(
    NAME fpu
    FILES
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_top.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_ctrl.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_addsub.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_cmp.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_cvt.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_div.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_mul.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/fpu_sqrt.sv
)