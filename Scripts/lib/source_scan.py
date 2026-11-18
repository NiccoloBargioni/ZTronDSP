"""Reads source files the way the lints need them: with comments and string contents blanked.

`mask_swift` and `mask_c` return a text of the same length as their input in which every
character of a comment or of a string literal's content is a space (newlines are kept), so a
match in the masked text has the line and column of the original. Code inside a Swift string
interpolation stays visible: it is code.

`tokens` splits masked Swift into identifiers and punctuation, each with its offset.
"""

import re

C_EXTENSIONS = (".c", ".h", ".m", ".mm", ".cpp", ".hpp", ".metal")


def _blank(character):
    return character if character == "\n" else " "


def mask_swift(text):
    out = []
    length = len(text)
    index = 0
    # Each open string: (number of '#', is multi-line). Each open interpolation: parenthesis depth.
    stack = []

    def in_string():
        return bool(stack) and stack[-1][0] == "string"

    while index < length:
        character = text[index]
        if in_string():
            _, hashes, multiline = stack[-1]
            closer = ('"""' if multiline else '"') + "#" * hashes
            escape = "\\" + "#" * hashes
            if text.startswith(closer, index):
                out.append(" " * len(closer))
                index += len(closer)
                stack.pop()
                continue
            if text.startswith(escape, index):
                after = index + len(escape)
                if after < length and text[after] == "(":
                    out.append(" " * len(escape) + "(")
                    index = after + 1
                    stack.append(("interpolation", 1, None))
                    continue
                # An escaped character: blank the escape and what it escapes.
                out.append(" " * len(escape))
                index = after
                if index < length:
                    out.append(_blank(text[index]))
                    index += 1
                continue
            if character == "\n" and not multiline:
                # An unterminated single-line literal: give up on it at the end of the line.
                stack.pop()
                out.append("\n")
                index += 1
                continue
            out.append(_blank(character))
            index += 1
            continue

        # Code, at the top level or inside an interpolation.
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = length if end < 0 else end
            out.append(" " * (end - index))
            index = end
            continue
        if text.startswith("/*", index):
            depth, cursor = 1, index + 2
            while cursor < length and depth:
                if text.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif text.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            out.append("".join(_blank(c) for c in text[index:cursor]))
            index = cursor
            continue
        match = re.compile(r'(#*)("""|")').match(text, index)
        if match and (match.group(1) == "" or text[index] == "#"):
            hashes = len(match.group(1))
            multiline = match.group(2) == '"""'
            out.append(" " * len(match.group(0)))
            index = match.end()
            stack.append(("string", hashes, multiline))
            continue
        if stack and stack[-1][0] == "interpolation":
            if character == "(":
                stack[-1] = ("interpolation", stack[-1][1] + 1, None)
            elif character == ")":
                depth = stack[-1][1] - 1
                if depth == 0:
                    stack.pop()
                else:
                    stack[-1] = ("interpolation", depth, None)
        out.append(character)
        index += 1
    return "".join(out)


def mask_c(text):
    """Blanks comments, string and character literals of C, Objective-C and Metal sources.

    Preprocessor lines are left as they are: `#include "UIKit/UIKit.h"` has to stay readable.
    """
    out = []
    length = len(text)
    index = 0
    line_start = True
    while index < length:
        character = text[index]
        if line_start:
            match = re.compile(r"[ \t]*#[^\n]*").match(text, index)
            if match:
                directive = match.group(0)
                comment = directive.find("//")
                if comment >= 0:
                    directive = directive[:comment] + " " * (len(directive) - comment)
                out.append(directive)
                index = match.end()
                line_start = False
                continue
        if character == "\n":
            out.append("\n")
            index += 1
            line_start = True
            continue
        if character not in " \t":
            line_start = False
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = length if end < 0 else end
            out.append(" " * (end - index))
            index = end
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = length if end < 0 else end + 2
            out.append("".join(_blank(c) for c in text[index:end]))
            index = end
            continue
        if character in "\"'":
            cursor = index + 1
            while cursor < length and text[cursor] != character and text[cursor] != "\n":
                cursor += 2 if text[cursor] == "\\" else 1
            cursor = min(cursor + 1, length)
            out.append(character + " " * max(cursor - index - 2, 0) + (character if cursor - index >= 2 else ""))
            index = cursor
            continue
        out.append(character)
        index += 1
    return "".join(out)


def mask(path, text):
    return mask_c(text) if path.endswith(C_EXTENSIONS) else mask_swift(text)


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|->|\n|[^\sA-Za-z0-9_]|[0-9][A-Za-z0-9_.]*")


def tokens(masked):
    """[(text, offset)] of masked Swift: identifiers, numbers, newlines and single punctuation marks."""
    return [(match.group(0), match.start()) for match in TOKEN.finditer(masked)]
