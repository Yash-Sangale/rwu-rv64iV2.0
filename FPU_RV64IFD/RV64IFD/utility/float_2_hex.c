#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef union float_2_hex
{
    double d;
    uint64_t u;
} fp64_t;

int main(int argc, char *argv[])
{
    if (argc < 2)
    {
        printf("Usage: %s <floating_point_number>\n", argv[0]);
        return 1;
    }
    fp64_t val;
    // Convert command-line string to double
    val.d = atof(argv[1]);
    // Print decimal input
    printf("Input float : %f\n", val.d);
    // Print IEEE754 hex
    printf("IEEE754 HEX   : 64'h%016llX\n", val.u);

    return 0;
}