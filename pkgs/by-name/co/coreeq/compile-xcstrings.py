#!/usr/bin/env python3
"""Compile an Apple String Catalog (.xcstrings) into .strings and .stringsdict.

Xcode compiles String Catalogs with `xcstringstool`, which ships only with
Xcode; the SwiftPM build system shells out to it, so a package built without
Xcode cannot process `.xcstrings` files. This reproduces the part of that
pipeline that a bundle needs at runtime:

- entries with a plain source-language string go into `<table>.strings`;
- entries whose source language has plural variations, and entries using
  substitutions (`%#@name@` in the string), go into `<table>.stringsdict`,
  keyed by their original string.

The stringsdict shapes are the ones the runtime formats correctly, checked
against Foundation itself (an entry's plural rule owns its whole sentence,
including the format spec; a substitution's variable consumes its argument in
order, so positional prefixes before the first variable reference are dropped,
and `%arg` becomes the variable's real format spec).

Only the source language is emitted. CoreEQ ships English only, and keys
without a source-language entry are skipped: the runtime then formats the key
itself, which is exactly what it would do with the entry present, since for
the source language the value is the key.

usage: compile-xcstrings.py CATALOG.xcstrings SOURCE_LANGUAGE OUTPUT_DIR
"""

import json
import plistlib
import re
import sys

# A printf-style format specification, including length modifiers and
# positional prefixes (`%1$lld`, `%@`, `%d`, ...).
FORMAT_SPEC = re.compile(r"%(?:[0-9]+\$)?(?:ll|hh|h|l)?[diouxXeEfgGcsSpaA@]")
# A positional prefix within such a specification (`1$` in `%1$lld`).
POSITIONAL_PREFIX = re.compile(r"%([0-9]+\$)")


def fail(message):
    print(f"compile-xcstrings: {message}", file=sys.stderr)
    sys.exit(1)


def format_value_type(spec):
    """The `NSStringFormatValueTypeKey` for a specification: `%1$lld` -> lld."""
    return spec[1:].lstrip("0123456789$")


def string_unit(unit, key):
    if "variations" in unit or "stringUnit" not in unit:
        fail(f"{key!r}: unit without a stringUnit")
    return unit["stringUnit"]["value"]


def plural_variable(units, value_type, key):
    """A stringsdict variable dict for the plural units of one entry."""
    variable = {
        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
        "NSStringFormatValueTypeKey": value_type,
    }
    for unit in sorted(units):
        variable[unit] = string_unit(units[unit], key)
    return variable


def entry_output(key, entry, language):
    """What to emit for one catalog entry: ("skip", None), ("plain", (key,
    value)) or ("plural", (table-key, stringsdict-entry))."""
    source = entry.get("localizations", {}).get(language, {})
    variations = source.get("variations", {})
    if "device" in variations:
        fail(f"{key!r}: device variations are not supported")

    # An entry whose whole string is one plural rule: the key carries the
    # sentence and the single format spec, the variable carries everything.
    units = variations.get("plural", {})
    if units:
        specs = FORMAT_SPEC.findall(key)
        if len(specs) != 1:
            fail(f"{key!r}: plural keys with exactly one format spec are supported")
        return "plural", (
            key,
            {
                "NSStringLocalizedFormatKey": "%#@count@",
                "count": plural_variable(units, format_value_type(specs[0]), key),
            },
        )

    substitutions = source.get("substitutions", {})
    if substitutions:
        value = string_unit(source, key)
        if "%arg" in key:
            fail(f"{key!r}: substitutions in the key itself are not supported")
        for name, substitution in substitutions.items():
            if value.count(f"%#@{name}@") != 1:
                fail(f"{key!r}: substitution {name!r} referenced more than once")
            spec = substitution.get("formatSpecifier")
            if not spec:
                fail(f"{key!r}: substitution {name!r} without a formatSpecifier")
            substitution_units = substitution.get("variations", {}).get("plural", {})
            if not substitution_units:
                fail(f"{key!r}: substitution {name!r} without plural variations")
            if any("%#@" in string_unit(u, key) for u in substitution_units.values()):
                fail(f"{key!r}: nested substitutions are not supported")
        # Variables bind their argument in order of appearance, so a
        # positional prefix before the first reference makes the variable
        # consume the wrong argument; drop those, keep the later ones.
        first_reference = value.find("%#@")
        format_key = (
            POSITIONAL_PREFIX.sub("%", value[:first_reference]) + value[first_reference:]
        )
        variables = {
            name: plural_variable(
                substitution["variations"]["plural"],
                substitution["formatSpecifier"],
                key,
            )
            for name, substitution in substitutions.items()
        }
        # `%arg` is the authoring form of the variable's own argument; the
        # runtime needs the real specification.
        for variable in variables.values():
            for unit in variable:
                if unit.startswith("NSString"):
                    continue
                variable[unit] = variable[unit].replace(
                    "%arg", "%" + variable["NSStringFormatValueTypeKey"]
                )
        return "plural", (
            key,
            {"NSStringLocalizedFormatKey": format_key, **variables},
        )

    value = source.get("stringUnit", {}).get("value")
    if value is None:
        return "skip", None
    return "plain", (key, value)


def main():
    if len(sys.argv) != 4:
        fail("usage: compile-xcstrings.py CATALOG.xcstrings SOURCE_LANGUAGE OUTPUT_DIR")
    catalog_path, language, out_dir = sys.argv[1:]
    table = catalog_path.rsplit("/", 1)[-1].removesuffix(".xcstrings")

    try:
        with open(catalog_path, "rb") as f:
            catalog = json.load(f)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{catalog_path}: {error}")

    plain = {}
    plural = {}
    skipped = 0
    for key, entry in sorted(catalog.get("strings", {}).items()):
        kind, payload = entry_output(key, entry, language)
        if kind == "skip":
            skipped += 1
        elif kind == "plain":
            key, value = payload
            if key in plain or key in plural:
                fail(f"{key!r}: duplicate key")
            plain[key] = value
        elif kind == "plural":
            key, stringsdict_entry = payload
            if key in plain or key in plural:
                fail(f"{key!r}: duplicate key")
            plural[key] = stringsdict_entry
        else:
            fail(f"{key!r}: unknown entry kind {kind!r}")

    with open(f"{out_dir}/{table}.strings", "wb") as f:
        plistlib.dump(plain, f, fmt=plistlib.FMT_XML)
    if plural:
        with open(f"{out_dir}/{table}.stringsdict", "wb") as f:
            plistlib.dump(plural, f, fmt=plistlib.FMT_XML)

    print(
        f"compile-xcstrings: {table}: {len(plain)} strings, "
        f"{len(plural)} plural entries, {skipped} untranslated keys skipped"
    )


if __name__ == "__main__":
    main()
