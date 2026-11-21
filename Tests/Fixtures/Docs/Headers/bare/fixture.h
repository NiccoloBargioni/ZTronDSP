// Seeded for Scripts/tests/test-docs.sh: a function of a public header without a comment.
#ifndef FIXTURE_BARE_H
#define FIXTURE_BARE_H

/// A level and its time.
typedef struct fixture_level {
    float decibels;   // the level
    double time;      // its time, in seconds
} fixture_level;

fixture_level fixture_quieter(fixture_level a, fixture_level b);

#endif
