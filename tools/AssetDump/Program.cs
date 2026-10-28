// AssetDump: headless reader for the game's IoStore paks (CUE4Parse, the library behind FModel).
//   AssetDump <paks dir> <EGame name, e.g. GAME_UE5_4> list <out.txt>          every file path
//   AssetDump <paks dir> <EGame> json <package path> <out.json> [usmap]       a package's exports as JSON
//   AssetDump <paks dir> <EGame> names <filter> <out.txt>                      the name maps of matching packages
// Game data never goes into git: write outputs under the gitignored dumps/ / extracted/ folders.
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.MappingsProvider;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Versions;
using Newtonsoft.Json;

if (args.Length < 3)
{
    Console.Error.WriteLine("usage: AssetDump <paks dir> <EGame> list|json|names ...");
    return 1;
}

var game = Enum.Parse<EGame>(args[1]);
OodleHelper.Initialize();
var provider = new DefaultFileProvider(args[0], SearchOption.TopDirectoryOnly, new VersionContainer(game));
provider.ReadScriptData = true;     // keep Blueprint bytecode (function graphs) in json exports
provider.Initialize();
provider.SubmitKey(new FGuid(), new FAesKey(new byte[32]));
provider.PostMount();
Console.Error.WriteLine($"[dump] {provider.Files.Count} files mounted ({game})");

switch (args[2])
{
    case "list":
        File.WriteAllLines(args[3], provider.Files.Keys.OrderBy(k => k));
        break;
    case "json":
        if (args.Length > 5)
            provider.MappingsContainer = new FileUsmapTypeMappingsProvider(args[5]);
        var pkg = provider.LoadPackage(args[3]);
        File.WriteAllText(args[4], JsonConvert.SerializeObject(pkg.GetExports(), Formatting.Indented));
        break;
    case "png":         // AssetDump <paks> <EGame> png <texture package> <out.png> [usmap]: a texture decoded to PNG
        if (args.Length > 5)
            provider.MappingsContainer = new FileUsmapTypeMappingsProvider(args[5]);
        var texPkg = provider.LoadPackage(args[3]);
        var tex = texPkg.GetExports().OfType<CUE4Parse.UE4.Assets.Exports.Texture.UTexture2D>().First();
        var bmp = CUE4Parse_Conversion.Textures.TextureDecoder.Decode(tex);
        using (var sk = CUE4Parse_Conversion.Textures.TextureEncoder.ToSkBitmap(bmp!))
        using (var fs = File.Create(args[4]))
            sk.Encode(fs, SkiaSharp.SKEncodedImageFormat.Png, 100);
        Console.Error.WriteLine($"[dump] {tex.Name}: {bmp.Width} x {bmp.Height} {bmp.PixelFormat}");
        break;
    case "raw":         // AssetDump <paks> <EGame> raw <file path> <out file>: the file's bytes (ini, txt, ...)
        File.WriteAllBytes(args[4], provider.SaveAsset(args[3]));
        break;
    case "names":       // AssetDump <paks> <EGame> names <path part> <out file> [usmap]: every matching package's names
        if (args.Length > 5)
            provider.MappingsContainer = new FileUsmapTypeMappingsProvider(args[5]);
        using (var w = new StreamWriter(args[4]))
        {
            foreach (var path in provider.Files.Keys.Where(k => k.Contains(args[3], StringComparison.OrdinalIgnoreCase)
                         && (k.EndsWith(".uasset") || k.EndsWith(".umap"))).OrderBy(k => k))
            {
                try
                {
                    var p = provider.LoadPackage(path);
                    w.WriteLine($"=== {path}");
                    foreach (var n in p.NameMap)
                        w.WriteLine("  " + n.Name);
                }
                catch (Exception e)
                {
                    w.WriteLine($"=== {path} FAILED {e.GetType().Name}: {e.Message}");
                }
            }
        }
        break;
}
return 0;
