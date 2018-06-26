/++
 +  This module contains the `meldInto` functions; functions that take two
 +  structs and combines them, creating a resulting struct with values from both
 +  parent structs. Array and associative array variants exist too.
 +/
module kameloso.meld;

import std.typecons : Flag, No, Yes;
import std.traits : isArray, isAssociativeArray;

// meldInto
/++
 +  Takes two structs and melds them together, making the members a union of
 +  the two.
 +
 +  It only overwrites members in `intoThis` that are `typeof(member).init`, so
 +  only unset members get their values overwritten by the melding struct.
 +  Supply a template parameter `Yes.overwrite` to make it always overwrite,
    except if the melding struct's member is `typeof(member).init`.
 +
 +  Example:
 +  ---
 +  struct Foo
 +  {
 +      string abc;
 +      int def;
 +  }
 +
 +  Foo foo, bar;
 +  foo.abc = "from foo"
 +  bar.def = 42;
 +  foo.meldInto(bar);
 +
 +  assert(bar.abc == "from foo");
 +  assert(bar.def == 42);
 +  ---
 +
 +  Params:
 +      overwrite = Whether the source object should overwrite set (non-`init`)
 +          values in the receiving object.
 +      meldThis = Struct to meld (source).
 +      intoThis = Reference to struct to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = No.overwrite, Thing)
    (Thing meldThis, ref Thing intoThis) pure nothrow
if (is(Thing == struct) || is(Thing == class) && !is(intoThis == const) &&
    !is(intoThis == immutable))
{
    import kameloso.traits : hasElaborateInit, isOfAssignableType;
    import std.traits : isArray, isSomeString, isType;

    static if (!hasElaborateInit!Thing && !overwrite)
    {
        if (meldThis == Thing.init)
        {
            // We're merging an .init with something, and .init does not have
            // any special default values. Nothing would get melded, so exit early.
            return;
        }
    }

    foreach (immutable i, ref member; intoThis.tupleof)
    {
        static if (!isType!member)
        {
            alias T = typeof(member);

            static if (is(T == struct) || is(T == class))
            {
                // Recurse
                meldThis.tupleof[i].meldInto!overwrite(member);
            }
            else static if (isOfAssignableType!T)
            {
                static if (overwrite)
                {
                    static if (is(T == float))
                    {
                        import std.math : isNaN;

                        if (!meldThis.tupleof[i].isNaN)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else static if (is(T == bool))
                    {
                        member = meldThis.tupleof[i];
                    }
                    else
                    {
                        if (meldThis.tupleof[i] != Thing.init.tupleof[i])
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                }
                else
                {
                    static if (is(T == float))
                    {
                        import std.math : isNaN;

                        if (member.isNaN)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else static if (is(T == enum))
                    {
                        if (meldThis.tupleof[i] > member)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else static if (isArray!T && !isSomeString!T)
                    {
                        member ~= meldThis.tupleof[i];
                    }
                    else
                    {
                        /+  This is tricksy for bools. A value of false could be
                            false, or merely unset. If we're not overwriting,
                            let whichever side is true win out? +/

                        if ((member == T.init) ||
                            (member == Thing.init.tupleof[i]))
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                }
            }
            else
            {
                pragma(msg, T.stringof ~ " is not meldable!");
            }
        }
    }
}

///
unittest
{
    import std.conv : to;

    struct Foo
    {
        string abc;
        string def;
        int i;
        float f;
    }

    Foo f1; // = new Foo;
    f1.abc = "ABC";
    f1.def = "DEF";

    Foo f2; // = new Foo;
    f2.abc = "this won't get copied";
    f2.def = "neither will this";
    f2.i = 42;
    f2.f = 3.14f;

    f2.meldInto(f1);

    with (f1)
    {
        assert((abc == "ABC"), abc);
        assert((def == "DEF"), def);
        assert((i == 42), i.to!string);
        assert((f == 3.14f), f.to!string);
    }

    Foo f3; // new Foo;
    f3.abc = "abc";
    f3.def = "def";
    f3.i = 100_135;
    f3.f = 99.9f;

    Foo f4; // new Foo;
    f4.abc = "OVERWRITTEN";
    f4.def = "OVERWRITTEN TOO";
    f4.i = 0;
    f4.f = 0.1f;

    f4.meldInto!(Yes.overwrite)(f3);

    with (f3)
    {
        assert((abc == "OVERWRITTEN"), abc);
        assert((def == "OVERWRITTEN TOO"), def);
        assert((i == 100_135), i.to!string); // 0 is int.init
        assert((f == 0.1f), f.to!string);
    }

    struct User
    {
        enum Class { anyone, blacklist, whitelist, admin }
        string nickname;
        string alias_;
        string ident;
        string address;
        string login;
        bool special;
        Class class_;
    }

    User one;
    with (one)
    {
        nickname = "kameloso";
        ident = "NaN";
        address = "herpderp.net";
        special = false;
        class_ = User.Class.whitelist;
    }

    User two;
    with (two)
    {
        nickname = "kameloso^";
        alias_ = "Kameloso";
        address = "asdf.org";
        login = "kamelusu";
        special = true;
        class_ = User.Class.blacklist;
    }

    User twoCopy = two;

    one.meldInto!(No.overwrite)(two);
    with (two)
    {
        assert((nickname == "kameloso^"), nickname);
        assert((alias_ == "Kameloso"), alias_);
        assert((ident == "NaN"), ident);
        assert((address == "asdf.org"), address);
        assert((login == "kamelusu"), login);
        assert(special);
        assert((class_ == User.Class.whitelist), class_.to!string);
    }

    one.class_ = User.Class.blacklist;

    one.meldInto!(Yes.overwrite)(twoCopy);
    with (twoCopy)
    {
        assert((nickname == "kameloso"), nickname);
        assert((alias_ == "Kameloso"), alias_);
        assert((ident == "NaN"), ident);
        assert((address == "herpderp.net"), address);
        assert((login == "kamelusu"), login);
        assert(!special);
        assert((class_ == User.Class.blacklist), class_.to!string);
    }

    struct EnumThing
    {
        enum Enum { unset, one, two, three }
        Enum enum_;
    }

    EnumThing e1;
    EnumThing e2;
    e2.enum_ = EnumThing.Enum.three;
    assert((e1.enum_ == EnumThing.Enum.init), e1.enum_.to!string);
    e2.meldInto(e1);
    assert((e1.enum_ == EnumThing.Enum.three), e1.enum_.to!string);

    struct WithArray
    {
        string[] arr;
    }

    WithArray w1, w2;
    w1.arr = [ "arr", "matey", "I'ma" ];
    w2.arr = [ "pirate", "stereotype", "unittest" ];
    w2.meldInto(w1);
    assert((w1.arr == [ "arr", "matey", "I'ma", "pirate", "stereotype", "unittest" ]), w1.arr.to!string);

    struct Server
    {
        string address;
    }

    struct Bot
    {
        string nickname;
        Server server;
    }

    Bot b1, b2;
    b1.nickname = "kameloso";
    b1.server.address = "freenode.net";

    assert(!b2.nickname.length, b2.nickname);
    assert(!b2.server.address.length, b2.nickname);
    b1.meldInto(b2);
    assert((b2.nickname == "kameloso"), b2.nickname);
    assert((b2.server.address == "freenode.net"), b2.server.address);

    b2.nickname = "harbl";
    b2.server.address = "rizon.net";

    b2.meldInto!(Yes.overwrite)(b1);
    assert((b1.nickname == "harbl"), b1.nickname);
    assert((b1.server.address == "rizon.net"), b1.server.address);
}


// meldInto (array)
/++
 +  Takes two arrays and melds them together, making a union of the two.
 +
 +  It only overwrites members that are `T.init`, so only unset
 +  fields get their values overwritten by the melding array. Supply a
 +  template parameter `Yes.overwrite` to make it overwrite if the melding
 +  array's field is not `T.init`.
 +
 +  Example:
 +  ---
 +  int[] arr1 = [ 1, 2, 3, 0, 0, 0 ];
 +  int[] arr2 = [ 0, 0, 0, 4, 5, 6 ];
 +  arr1.meldInto!(No.overwrite)(arr2);
 +
 +  assert(arr2 == [ 1, 2, 3, 4, 5, 6 ]);
 +  ---
 +
 +  Params:
 +      overwrite = Whether the source array should overwrite set (non-`init`)
 +          values in the receiving array.
 +      meldThis = Array to meld (source).
 +      intoThis = Reference to the array to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = Yes.overwrite, Array1, Array2)
    (Array1 meldThis, ref Array2 intoThis) pure nothrow
if (isArray!Array1 && isArray!Array2 && !is(Array2 == const)
    && !is(Array2 == immutable))
{
    import std.traits : isDynamicArray, isStaticArray;

    static if (isDynamicArray!Array2)
    {
        // Ensure there's room for all elements
        if (meldThis.length > intoThis.length) intoThis.length = meldThis.length;
    }
    else static if (isStaticArray!Array2)
    {
        assert((intoThis.length >= meldThis.length), "Can't meld a larger array into a smaller static one");
    }
    else
    {
        static assert(0);
    }

    foreach (immutable i, val; meldThis)
    {
        if (val == typeof(val).init) continue;

        static if (overwrite)
        {
            intoThis[i] = val;
        }
        else
        {
            if ((val != typeof(val).init) && (intoThis[i] == typeof(intoThis[i]).init))
            {
                intoThis[i] = val;
            }
        }
    }
}

///
unittest
{
    import std.conv : to;
    import std.typecons : Yes, No;

    auto arr1 = [ 123, 0, 789, 0, 456, 0 ];
    auto arr2 = [ 0, 456, 0, 123, 0, 789 ];
    arr1.meldInto!(No.overwrite)(arr2);
    assert((arr2 == [ 123, 456, 789, 123, 456, 789 ]), arr2.to!string);

    auto yarr1 = [ 'Z', char.init, 'Z', char.init, 'Z' ];
    auto yarr2 = [ 'A', 'B', 'C', 'D', 'E', 'F' ];
    yarr1.meldInto!(Yes.overwrite)(yarr2);
    assert((yarr2 == [ 'Z', 'B', 'Z', 'D', 'Z', 'F' ]), yarr2.to!string);

    auto harr1 = [ char.init, 'X' ];
    yarr1.meldInto(harr1);
    assert((harr1 == [ 'Z', 'X', 'Z', char.init, 'Z' ]), harr1.to!string);

    char[5] harr2 = [ '1', '2', '3', '4', '5' ];
    char[] harr3;
    harr2.meldInto(harr3);
    assert((harr2 == harr3), harr3.to!string);
}


// meldInto
/++
 +  Takes two associative arrays and melds them together, making a union of the
 +  two.
 +
 +  This is largely the same as the array-version `meldInto` but doesn't need
 +  the extensive template constraints it employs, so it might as well be kept
 +  separate.
 +
 +  Example:
 +  ---
 +  int[string] aa1 = [ "abc" : 42, "def" : -1 ];
 +  int[string] aa2 = [ "ghi" : 10, "jkl" : 7 ];
 +  arr1.meldInto(arr2);
 +
 +  assert("abc" in aa2);
 +  assert("def" in aa2);
 +  assert("ghi" in aa2);
 +  assert("jkl" in aa2);
 +  ---
 +
 +  Params:
 +      overwrite = Whether the source associative array should overwrite set
 +          (non-`init`) values in the receiving object.
 +      meldThis = Associative array to meld (source).
 +      intoThis = Reference to the associative array to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = Yes.overwrite, AA)(AA meldThis, ref AA intoThis) pure
if (isAssociativeArray!AA)
{
    foreach (key, val; meldThis)
    {
        static if (overwrite)
        {
            intoThis[key] = val;
        }
        else
        {
            if ((val != typeof(val).init) && (intoThis[key] == typeof(intoThis[i]).init))
            {
                intoThis[i] = val;
            }
        }
    }
}

///
unittest
{
    bool[string] aa1;
    bool[string] aa2;

    aa1["a"] = true;
    aa1["b"] = false;
    aa2["c"] = true;
    aa2["d"] = false;

    assert("a" in aa1);
    assert("b" in aa1);
    assert("c" in aa2);
    assert("d" in aa2);

    aa1.meldInto(aa2);

    assert("a" in aa2);
    assert("b" in aa2);
}


