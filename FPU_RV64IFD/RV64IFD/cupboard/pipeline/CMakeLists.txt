# Pipeline RTL module

register_rtl_module(
    NAME pipeline
    FILES
        ${CMAKE_CURRENT_SOURCE_DIR}/if_stage.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/id_stage.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/ex_stage.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/mem_stage.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/wb_stage.sv
)