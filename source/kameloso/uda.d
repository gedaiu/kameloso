module kameloso.uda;

/// UDA conveying that a field is not to be saved in configuration files
struct Unconfigurable {}

/// UDA conveying that a string is an array with this token as separator
struct Separator
{
    /// Separator, can be more than one character
    string token = ",";
}

/++
 +  UDA conveying that this member contains sensitive information and should not
 +  be printed in clear text; e.g. passwords.
 +/
struct Hidden {}
