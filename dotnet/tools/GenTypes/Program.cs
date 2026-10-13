// Sync the erupt schemas into the library and regenerate src/Erupt.Sdk/Types.g.cs from them.
//
//   dotnet run --project tools/GenTypes -- <erupt repo>/schema          copy schemas, regenerate types
//   dotnet run --project tools/GenTypes -- <erupt repo>/schema --check  fail when anything is out of date (CI)
using Erupt.GenTypes;

var positional = args.Where(a => !a.StartsWith("--")).ToArray();
if (positional.Length != 1)
{
    Console.Error.WriteLine("usage: GenTypes <schema dir> [--check]");
    return 2;
}
var check = args.Contains("--check");
var schemaDir = Path.GetFullPath(positional[0]);

// the library lives next to tools/: walk up from the working directory to find it
var root = new DirectoryInfo(Directory.GetCurrentDirectory());
while (root is not null && !File.Exists(Path.Combine(root.FullName, "src", "Erupt.Sdk", "Erupt.Sdk.csproj"))) root = root.Parent;
if (root is null)
{
    Console.Error.WriteLine("run from inside the dotnet/ directory");
    return 2;
}
var library = Path.Combine(root.FullName, "src", "Erupt.Sdk");

var expected = new Dictionary<string, string>();
foreach (var file in Generator.Resources)
{
    var source = Path.Combine(schemaDir, file);
    if (!File.Exists(source))
    {
        Console.Error.WriteLine($"missing {source}");
        return 2;
    }
    expected[Path.Combine(library, "Resources", file)] = File.ReadAllText(source);
}
expected[Path.Combine(library, "Types.g.cs")] =
    Generator.Generate(expected[Path.Combine(library, "Resources", "erupt-annotations.schema.json")]);

var stale = expected.Where(e => !File.Exists(e.Key) || File.ReadAllText(e.Key) != e.Value).Select(e => e.Key).ToList();
foreach (var path in stale)
{
    if (check)
    {
        Console.WriteLine($"stale: {Path.GetRelativePath(root.FullName, path)}");
        continue;
    }
    File.WriteAllText(path, expected[path]);
    Console.WriteLine($"wrote {Path.GetRelativePath(root.FullName, path)}");
}
return check && stale.Count > 0 ? 1 : 0;
