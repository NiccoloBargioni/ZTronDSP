// flags: -parse-as-library -D FIXTURE_FLAG
#if FIXTURE_FLAG
@main struct Entry {
    static func main() {}
}
#else
#error("the flag of the header did not reach the compiler")
#endif
