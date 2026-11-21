// The C half of the documentation fixture: every declaration has a comment (Scripts/tests/test-docs.sh).
#ifndef FIXTURE_H
#define FIXTURE_H

/// The largest level, in decibels.
#define FIXTURE_CEILING 0

/// A level and its time.
typedef struct fixture_level {
    float decibels;   // the level
    double time;      // its time, in seconds
} fixture_level;

/// The louder of two levels. Nonblocking: it does not allocate.
fixture_level fixture_louder(fixture_level a, fixture_level b);

#endif
