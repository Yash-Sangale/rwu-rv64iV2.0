# ALU RTL module

register_rtl_module(
    NAME alu
    FILES
        ${CMAKE_CURRENT_SOURCE_DIR}/alu_top.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/alu_ctrl.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/shifter.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/comparator.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/mul_div.sv
)