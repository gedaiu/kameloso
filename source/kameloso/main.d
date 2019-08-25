/++
 +  Dummy main module so the main `kameloso.d` gets tested by dub.
 +/
module kameloso.main;

version(unittest)
/++
 +  Unit-testing main; does nothing.
 +/
void main()
{
    import kameloso.common : logger;

    version(Windows)
    {
        import kameloso.terminal : setConsoleModeAndCodepage;

        // Set up the console to display text and colours properly.
        // It will only affect the below "All tests passed" line however...
        setConsoleModeAndCodepage();
    }

    // Compiled with -b unittest, so run the tests and exit.
    // Logger is initialised in a module constructor, don't re-init here.
    logger.info("All tests passed successfully!");
    // No need to Cygwin-flush; the logger did that already
}
else
/++
 +  Entry point of the program.
 +
 +  Technically it just passes on execution to `kameloso.kameloso.initBot`.
 +
 +  Params:
 +      args = Command-line arguments passed to the program.
 +
 +  Returns:
 +      `0` on success, `1` on failure.
 +/
int main(string[] args)
{
    import kameloso.kameloso : initBot;

    return initBot(args);
}
