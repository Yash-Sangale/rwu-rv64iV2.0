int main() {
    int a = 40;
    int b = 20;
    
    if ((a + b) == 60) {
        return 0; // x10 becomes 0 (PASS)
    } else {
        return 1; // x10 becomes 1 (FAIL)
    }
}