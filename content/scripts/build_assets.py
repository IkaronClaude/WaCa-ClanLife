"""Builds the WaCa content assets inside the content project (run by tools/build_content.ps1 through
UnrealEditor-Cmd -run=pythonscript). Everything under /Game/Mods/WaCa is (re)made from content/source + this script:

  /Game/Mods/WaCa/Weather/SM_WaCaPrecipCylinder   the open cylinder the weather is drawn on (content/source .obj)
  /Game/Mods/WaCa/Weather/M_WaCaPrecip            falling streaks / flakes: one Custom HLSL node, all parameters
  /Game/Mods/WaCa/Weather/MI_WaCaRain, MI_WaCaSnow  its looks
  /Game/Mods/WaCa/Weather/SW_WaCaRainLoop         the rain sound (looping)
  /Game/Mods/WaCa/Label_WaCaContent               puts all of it in chunk 7701 (= the mod's own pak)
"""
import os

import unreal

ROOT = "/Game/Mods/WaCa"
WEATHER = ROOT + "/Weather"
SOURCE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "source"))
CHUNK = 7701

tools = unreal.AssetToolsHelpers.get_asset_tools()
lib = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary
# headless: an import must not try to show its asset in the Content Browser (no UI in a commandlet - it asserts)
unreal.SystemLibrary.execute_console_command(None, "Interchange.FeatureFlags.Import.SyncToBrowser 0")


def log(msg):
    unreal.log("[WaCaContent] " + msg)


def fresh(path):
    if lib.does_asset_exist(path):
        lib.delete_asset(path)


def import_file(filename, dest, name, options=None):
    fresh(dest + "/" + name)
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", os.path.join(SOURCE, filename))
    task.set_editor_property("destination_path", dest)
    task.set_editor_property("destination_name", name)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("save", False)
    if options:
        task.set_editor_property("options", options)
    tools.import_asset_tasks([task])
    asset = lib.load_asset(dest + "/" + name)
    if not asset:
        raise RuntimeError("import failed: " + filename)
    log("imported %s -> %s (%s)" % (filename, asset.get_path_name(), asset.get_class().get_name()))
    return asset


# --- mesh + sound -------------------------------------------------------------------------------------------------
mesh = import_file("SM_WaCaPrecipCylinder.obj", WEATHER, "SM_WaCaPrecipCylinder")
# a plain mesh: no Nanite (UE 5.7 may turn it on for imports - loading it crashed the game's GPU device on the VM),
# no collision, no distance field (it never casts or blocks anything)
nanite = mesh.get_editor_property("nanite_settings")
log("mesh Nanite was %s" % nanite.get_editor_property("enabled"))
nanite.set_editor_property("enabled", False)
mesh.set_editor_property("nanite_settings", nanite)
mesh.set_editor_property("generate_mesh_distance_field", False) if hasattr(mesh, "generate_mesh_distance_field") else None
body = mesh.get_editor_property("body_setup")
if body:
    body.set_editor_property("collision_trace_flag", unreal.CollisionTraceFlag.CTF_USE_SIMPLE_AS_COMPLEX)
sound = import_file("SW_WaCaRainLoop.wav", WEATHER, "SW_WaCaRainLoop")
sound.set_editor_property("looping", True)

# --- the material -------------------------------------------------------------------------------------------------
# Streaks fall down the cylinder's v (0 top -> 1 bottom). The surface is cut into Columns x Rows cells; each column
# falls at its own speed, each cell holds at most one drop (Density = the share of cells that do), offset sideways
# at random and swaying by Sway. Round = 0: a streak Length long, brightest at its leading end (rain); Round = 1:
# a soft blob Length tall (snow).
HLSL = r"""
float2 g = UV * float2(Columns, Rows);
float col = floor(g.x);
float h = frac(sin(col * 12.9898) * 43758.5453);
float y = g.y - T * Speed * (0.75 + 0.5 * h) - h * 13.0;
float cell = floor(y);
float fy = frac(y);
float r = frac(sin(dot(float2(col, cell), float2(127.1, 311.7))) * 43758.5453);
if (r > Density) return 0;
float xo = (frac(r * 91.7) - 0.5) * 0.6 + sin(T * 1.3 + cell * 2.1 + col) * Sway;
float dx = abs(frac(g.x) - 0.5 - xo);
float w = 1 - smoothstep(Width * 0.5, Width, dx);
float streak = fy < Length ? fy / Length : 0;
float blob = 1 - smoothstep(Length * 0.25, Length * 0.5, abs(fy - 0.5));
return w * lerp(streak, blob, Round);
"""

path = WEATHER + "/M_WaCaPrecip"
fresh(path)
mat = tools.create_asset("M_WaCaPrecip", WEATHER, unreal.Material, unreal.MaterialFactoryNew())
mat.set_editor_property("blend_mode", unreal.BlendMode.BLEND_TRANSLUCENT)
mat.set_editor_property("two_sided", True)
mat.set_editor_property("translucency_lighting_mode", unreal.TranslucencyLightingMode.TLM_VOLUMETRIC_NON_DIRECTIONAL)
mat.set_editor_property("used_with_static_lighting", False)

y = 0


def node(cls, x, yy):
    return mel.create_material_expression(mat, cls, x, yy)


def scalar(name, default, yy):
    p = node(unreal.MaterialExpressionScalarParameter, -900, yy)
    p.set_editor_property("parameter_name", name)
    p.set_editor_property("default_value", default)
    return p


custom = node(unreal.MaterialExpressionCustom, -500, 0)
custom.set_editor_property("code", HLSL)
custom.set_editor_property("output_type", unreal.CustomMaterialOutputType.CMOT_FLOAT1)
custom.set_editor_property("description", "WaCaPrecip")
names = ["UV", "T", "Columns", "Rows", "Speed", "Length", "Width", "Density", "Sway", "Round"]
inputs = []
for n in names:
    ci = unreal.CustomInput()
    ci.set_editor_property("input_name", n)
    inputs.append(ci)
custom.set_editor_property("inputs", inputs)

uv = node(unreal.MaterialExpressionTextureCoordinate, -900, -300)
time = node(unreal.MaterialExpressionTime, -900, -200)
mel.connect_material_expressions(uv, "", custom, "UV")
mel.connect_material_expressions(time, "", custom, "T")
defaults = {"Columns": 160.0, "Rows": 6.0, "Speed": 1.6, "Length": 0.35, "Width": 0.08, "Density": 0.45,
            "Sway": 0.0, "Round": 0.0}
for i, (n, v) in enumerate(defaults.items()):
    mel.connect_material_expressions(scalar(n, v, -100 + i * 80), "", custom, n)

# opacity = pattern x Opacity, softened where the cylinder cuts through the world (depth fade) and near the camera
opacity = scalar("Opacity", 0.35, 600)
mul = node(unreal.MaterialExpressionMultiply, -250, 100)
mel.connect_material_expressions(custom, "", mul, "A")
mel.connect_material_expressions(opacity, "", mul, "B")
fade = node(unreal.MaterialExpressionDepthFade, -100, 100)
mel.connect_material_expressions(mul, "", fade, "Opacity")
fade_dist = scalar("DepthFade", 60.0, 700)
mel.connect_material_expressions(fade_dist, "", fade, "FadeDistance")
# near-camera fade: saturate(PixelDepth / NearFade) (streaks right in front of the lens would be huge)
depth = node(unreal.MaterialExpressionPixelDepth, -100, 250)
near = scalar("NearFade", 120.0, 780)
ratio = node(unreal.MaterialExpressionDivide, 50, 250)
mel.connect_material_expressions(depth, "", ratio, "A")
mel.connect_material_expressions(near, "", ratio, "B")
sat = node(unreal.MaterialExpressionSaturate, 150, 250)
mel.connect_material_expressions(ratio, "", sat, "")
cam = node(unreal.MaterialExpressionMultiply, 250, 100)
mel.connect_material_expressions(fade, "", cam, "A")
mel.connect_material_expressions(sat, "", cam, "B")
mel.connect_material_property(cam, "", unreal.MaterialProperty.MP_OPACITY)

color = node(unreal.MaterialExpressionVectorParameter, -250, -250)
color.set_editor_property("parameter_name", "Color")
color.set_editor_property("default_value", unreal.LinearColor(0.75, 0.8, 0.9, 1.0))
mel.connect_material_property(color, "", unreal.MaterialProperty.MP_BASE_COLOR)
glow = scalar("Glow", 0.05, 860)
emissive = node(unreal.MaterialExpressionMultiply, -100, -150)
mel.connect_material_expressions(color, "", emissive, "A")
mel.connect_material_expressions(glow, "", emissive, "B")
mel.connect_material_property(emissive, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
mel.recompile_material(mat)
log("material %s" % mat.get_path_name())


def instance(name, values, color_value):
    p = WEATHER + "/" + name
    fresh(p)
    mi = tools.create_asset(name, WEATHER, unreal.MaterialInstanceConstant, unreal.MaterialInstanceConstantFactoryNew())
    mel.set_material_instance_parent(mi, mat)
    for k, v in values.items():
        mel.set_material_instance_scalar_parameter_value(mi, k, v)
    mel.set_material_instance_vector_parameter_value(mi, "Color", color_value)
    mel.update_material_instance(mi)
    log("instance %s" % mi.get_path_name())


instance("MI_WaCaRain", {"Columns": 160.0, "Rows": 6.0, "Speed": 1.6, "Length": 0.35, "Width": 0.08,
                         "Density": 0.45, "Sway": 0.0, "Round": 0.0, "Opacity": 0.35}, unreal.LinearColor(0.75, 0.8, 0.9, 1))
instance("MI_WaCaSnow", {"Columns": 90.0, "Rows": 14.0, "Speed": 0.25, "Length": 0.3, "Width": 0.22,
                         "Density": 0.35, "Sway": 0.15, "Round": 1.0, "Opacity": 0.8, "Glow": 0.15},
         unreal.LinearColor(1, 1, 1, 1))

# --- the chunk label: everything in /Game/Mods/WaCa -> chunk CHUNK (its own IoStore container) --------------------
label_path = ROOT + "/Label_WaCaContent"
fresh(label_path)
label = tools.create_asset("Label_WaCaContent", ROOT, unreal.PrimaryAssetLabel, unreal.DataAssetFactory())
rules = unreal.PrimaryAssetRules()
rules.set_editor_property("priority", 100)
rules.set_editor_property("chunk_id", CHUNK)
rules.set_editor_property("apply_recursively", True)
rules.set_editor_property("cook_rule", unreal.PrimaryAssetCookRule.ALWAYS_COOK)
label.set_editor_property("rules", rules)
label.set_editor_property("label_assets_in_my_directory", True)
log("label %s -> chunk %d" % (label.get_path_name(), CHUNK))

lib.save_directory(ROOT, only_if_is_dirty=False, recursive=True)
log("done")
