# build_runner.py — generates assets/runner.glb for the temple run clone.
#
# Authored as code so the model is reproducible and diffable:
#   ~/.local/opt/blender/blender --background --python assets/build_runner.py
#
# Output: runner.glb — one rigid-skinned blocky runner (matches the game's
# procedural aesthetic) with four clips: idle, run, jump, slide.
# The game scrubs `run` by distance, `jump` by vertical velocity, and loops
# idle/slide by time. Hats stay procedural in-game, attached to the "head"
# bone via model.currentPose.
#
# Conventions:
# - Blender Z-up, character faces +Y  ->  glTF/raylib Y-up, faces -Z
#   (the direction the game's runner travels).
# - Every mesh part is 100% weighted to exactly one bone (rigid segments).
# - Materials in creation order: body, pants, skin, accent, dark.
#   raylib maps them to model.materials[1..5] (index 0 is raylib's default).

import bpy
import math
import os
from mathutils import Vector

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# pose-rotation sign for bones pointing DOWN (limbs): +1 means positive
# local-X rotation swings the tail toward +Y (character forward).
S = -1.0
# same, for bones pointing UP (spine/head): forward lean sign.
SU = 1.0

FPS = 60

# --- scene ----------------------------------------------------------------

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = FPS

# --- materials (creation order defines glTF order) -------------------------

# SCOUT default palette; the game recolors per skin at runtime.
MAT_DEFS = [
    ("M_BODY",   (0.886, 0.345, 0.227)),  # shirt
    ("M_PANTS",  (0.243, 0.173, 0.157)),  # pants / limbs
    ("M_SKIN",   (0.953, 0.800, 0.659)),  # head / hands
    ("M_ACCENT", (1.000, 0.784, 0.157)),  # boots / sash
    ("M_DARK",   (0.070, 0.060, 0.070)),  # eyes
]
MATS = {}
for name, rgb in MAT_DEFS:
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*rgb, 1.0)
    m.diffuse_color = (*rgb, 1.0)  # workbench preview color
    MATS[name] = m

# --- armature ---------------------------------------------------------------

arm_data = bpy.data.armatures.new("runner_arm")
arm_obj = bpy.data.objects.new("runner_rig", arm_data)
scene.collection.objects.link(arm_obj)
bpy.context.view_layer.objects.active = arm_obj
bpy.ops.object.mode_set(mode='EDIT')

BONES = [
    # name, head, tail, parent
    ("pelvis",      (0.00, 0, 0.78), (0.00, 0, 0.95), None),
    ("spine",       (0.00, 0, 0.95), (0.00, 0, 1.45), "pelvis"),
    ("head",        (0.00, 0, 1.45), (0.00, 0, 1.80), "spine"),
    ("upper_arm.L", (+0.36, 0, 1.46), (+0.36, 0, 1.14), "spine"),
    ("forearm.L",   (+0.36, 0, 1.14), (+0.36, 0, 0.85), "upper_arm.L"),
    ("upper_arm.R", (-0.36, 0, 1.46), (-0.36, 0, 1.14), "spine"),
    ("forearm.R",   (-0.36, 0, 1.14), (-0.36, 0, 0.85), "upper_arm.R"),
    ("thigh.L",     (+0.15, 0, 0.78), (+0.15, 0, 0.38), "pelvis"),
    ("shin.L",      (+0.15, 0, 0.38), (+0.15, 0, 0.02), "thigh.L"),
    ("thigh.R",     (-0.15, 0, 0.78), (-0.15, 0, 0.38), "pelvis"),
    ("shin.R",      (-0.15, 0, 0.38), (-0.15, 0, 0.02), "thigh.R"),
]
for name, head, tail, parent in BONES:
    b = arm_data.edit_bones.new(name)
    b.head = Vector(head)
    b.tail = Vector(tail)
    b.roll = 0.0
    if parent is not None:
        b.parent = arm_data.edit_bones[parent]
bpy.ops.object.mode_set(mode='OBJECT')

# --- mesh parts ---------------------------------------------------------------

PARTS = [
    # name, bone, kind, center, size, material
    ("hips",   "pelvis",      "cube",   (0.00, 0.000, 0.840), (0.46, 0.32, 0.24), "M_PANTS"),
    ("torso",  "spine",       "cube",   (0.00, 0.000, 1.240), (0.56, 0.34, 0.60), "M_BODY"),
    ("sash",   "spine",       "cube",   (0.00, 0.176, 1.260), (0.42, 0.02, 0.14), "M_ACCENT"),
    ("skull",  "head",        "sphere", (0.00, 0.000, 1.700), (0.44, 0.44, 0.48), "M_SKIN"),
    ("eye.L",  "head",        "cube",   (+0.08, 0.190, 1.730), (0.05, 0.03, 0.05), "M_DARK"),
    ("eye.R",  "head",        "cube",   (-0.08, 0.190, 1.730), (0.05, 0.03, 0.05), "M_DARK"),
    ("uarm.L", "upper_arm.L", "cube",   (+0.36, 0.000, 1.300), (0.14, 0.14, 0.32), "M_BODY"),
    ("farm.L", "forearm.L",   "cube",   (+0.36, 0.000, 0.995), (0.115, 0.115, 0.29), "M_SKIN"),
    ("hand.L", "forearm.L",   "cube",   (+0.36, 0.000, 0.790), (0.13, 0.13, 0.13), "M_SKIN"),
    ("uarm.R", "upper_arm.R", "cube",   (-0.36, 0.000, 1.300), (0.14, 0.14, 0.32), "M_BODY"),
    ("farm.R", "forearm.R",   "cube",   (-0.36, 0.000, 0.995), (0.115, 0.115, 0.29), "M_SKIN"),
    ("hand.R", "forearm.R",   "cube",   (-0.36, 0.000, 0.790), (0.13, 0.13, 0.13), "M_SKIN"),
    ("thighm.L", "thigh.L",   "cube",   (+0.15, 0.000, 0.580), (0.21, 0.21, 0.40), "M_PANTS"),
    ("shinm.L",  "shin.L",    "cube",   (+0.15, 0.000, 0.200), (0.17, 0.17, 0.36), "M_PANTS"),
    ("boot.L",   "shin.L",    "cube",   (+0.15, 0.060, 0.060), (0.19, 0.30, 0.12), "M_ACCENT"),
    ("thighm.R", "thigh.R",   "cube",   (-0.15, 0.000, 0.580), (0.21, 0.21, 0.40), "M_PANTS"),
    ("shinm.R",  "shin.R",    "cube",   (-0.15, 0.000, 0.200), (0.17, 0.17, 0.36), "M_PANTS"),
    ("boot.R",   "shin.R",    "cube",   (-0.15, 0.060, 0.060), (0.19, 0.30, 0.12), "M_ACCENT"),
]

part_objs = []
for name, bone, kind, center, size, mat in PARTS:
    if kind == "sphere":
        bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=10, location=center)
    else:
        bpy.ops.mesh.primitive_cube_add(location=center)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (size[0] / 2, size[1] / 2, size[2] / 2)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(MATS[mat])
    vg = obj.vertex_groups.new(name=bone)
    vg.add(list(range(len(obj.data.vertices))), 1.0, 'REPLACE')
    part_objs.append(obj)

bpy.ops.object.select_all(action='DESELECT')
for o in part_objs:
    o.select_set(True)
bpy.context.view_layer.objects.active = part_objs[0]
bpy.ops.object.join()
runner = bpy.context.active_object
runner.name = "runner"
bpy.ops.object.shade_flat()

runner.parent = arm_obj
mod = runner.modifiers.new("Armature", 'ARMATURE')
mod.object = arm_obj

# --- posing helpers -------------------------------------------------------------

def clear_pose():
    for pb in arm_obj.pose.bones:
        pb.rotation_mode = 'XYZ'
        pb.rotation_euler = (0, 0, 0)
        pb.location = (0, 0, 0)

def set_pose(rx=None, twist=0.0, pelvis_drop=0.0):
    """rx: {bone: local-X angle}, positive = swing forward for limbs /
    lean forward for spine+head. pelvis_drop lowers the whole body (meters)."""
    rx = rx or {}
    for name, ang in rx.items():
        pb = arm_obj.pose.bones[name]
        sign = SU if name in ("spine", "head") else S
        pb.rotation_euler.x = sign * ang
    arm_obj.pose.bones["spine"].rotation_euler.y = twist
    # pelvis bone points up (+Z): local Y is along the bone.
    arm_obj.pose.bones["pelvis"].location.y = -pelvis_drop

def key_all(frame):
    for pb in arm_obj.pose.bones:
        pb.keyframe_insert("rotation_euler", frame=frame)
        pb.keyframe_insert("location", frame=frame)

def new_action(name):
    ad = arm_obj.animation_data or arm_obj.animation_data_create()
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    ad.action = act
    # Blender 4.4+ slotted actions: bind an object slot explicitly.
    if hasattr(act, "slots"):
        slot = act.slots.new(id_type='OBJECT', name=name)
        ad.action_slot = slot
    return act

def stash(act):
    ad = arm_obj.animation_data
    track = ad.nla_tracks.new()
    track.name = act.name
    track.strips.new(act.name, int(act.frame_range[0]), act)
    track.mute = True
    ad.action = None

# --- clip: run (60 frames = one full stride cycle, scrubbed by distance) --------

def run_pose(t):
    ph = 2 * math.pi * t
    return {
        "thigh.L": math.sin(ph) * 0.85,
        "thigh.R": -math.sin(ph) * 0.85,
        "shin.L": -(0.15 + 1.55 * max(math.cos(ph - 4.9), 0.0)),
        "shin.R": -(0.15 + 1.55 * max(math.cos(ph + math.pi - 4.9), 0.0)),
        "upper_arm.L": -math.sin(ph) * 0.75,
        "upper_arm.R": math.sin(ph) * 0.75,
        "forearm.L": 1.05 + 0.25 * max(-math.sin(ph), 0.0),
        "forearm.R": 1.05 + 0.25 * max(math.sin(ph), 0.0),
        "spine": 0.18,
        "head": -0.10,
    }, math.sin(ph) * 0.13

RUN_LEN = 60
act = new_action("run")
clear_pose()
for f in range(RUN_LEN + 1):  # +1 closes the loop
    rx, twist = run_pose(f / RUN_LEN)
    set_pose(rx, twist=twist)
    key_all(f)
run_act = act

# --- clip: jump (31 frames, frame 0 = tucked ascent, frame 30 = extended fall) ---

def jump_pose(tuck):
    return {
        "thigh.L": 0.45 + 1.05 * tuck,
        "shin.L": -(0.45 + 1.45 * tuck),
        "thigh.R": -0.15 + 0.55 * tuck,
        "shin.R": -(0.55 + 0.75 * tuck),
        "upper_arm.L": -0.2 - 0.9 * tuck,
        "forearm.L": 0.9,
        "upper_arm.R": 0.3 + 0.7 * tuck,
        "forearm.R": 1.3,
        "spine": 0.10,
        "head": -0.05,
    }

JUMP_LEN = 30
act = new_action("jump")
clear_pose()
for f in range(JUMP_LEN + 1):
    set_pose(jump_pose(1.0 - f / JUMP_LEN))
    key_all(f)
jump_act = act

# --- clip: slide (40-frame loop, reclined baseball slide) ------------------------

SLIDE_LEN = 40
act = new_action("slide")
clear_pose()
for f in range(SLIDE_LEN + 1):
    wob = math.sin(2 * math.pi * f / SLIDE_LEN) * 0.04
    set_pose({
        "thigh.L": 1.35,
        "shin.L": -0.20,
        "thigh.R": 1.05,
        "shin.R": -0.85,
        "upper_arm.L": -1.9,
        "forearm.L": 0.4,
        "upper_arm.R": 0.9,
        "forearm.R": 1.2,
        "spine": -1.15 + wob,
        "head": 0.85,        # keep the face pointing down the track
    }, twist=0.15, pelvis_drop=0.46)
    key_all(f)
slide_act = act

# --- clip: idle (120-frame loop, menu breathing) ---------------------------------

IDLE_LEN = 120
act = new_action("idle")
clear_pose()
for f in range(IDLE_LEN + 1):
    b = math.sin(2 * math.pi * f / IDLE_LEN)
    set_pose({
        "thigh.L": 0.04,
        "shin.L": -0.10,
        "thigh.R": -0.04,
        "shin.R": -0.10,
        "upper_arm.L": 0.06 + b * 0.02,
        "forearm.L": 0.25,
        "upper_arm.R": -0.06 - b * 0.02,
        "forearm.R": 0.25,
        "spine": 0.03 + b * 0.03,
        "head": -0.02,
    })
    key_all(f)
idle_act = act

# --- previews (workbench renders for visual sign/proportion checks) --------------

scene.render.engine = 'BLENDER_WORKBENCH'
scene.display.shading.color_type = 'MATERIAL'
scene.render.resolution_x = 512
scene.render.resolution_y = 512

cam_data = bpy.data.cameras.new("cam")
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam

def shoot(act, frame, cam_pos, cam_rot, out):
    arm_obj.animation_data.action = act
    if hasattr(act, "slots") and len(act.slots):
        arm_obj.animation_data.action_slot = act.slots[0]
    scene.frame_set(frame)
    cam.location = cam_pos
    cam.rotation_euler = cam_rot
    scene.render.filepath = os.path.join(OUT_DIR, out)
    bpy.ops.render.render(write_still=True)

FRONT = ((0, 3.6, 1.05), (math.radians(90), 0, math.radians(180)))
SIDE = ((3.6, 0, 1.05), (math.radians(90), 0, math.radians(90)))

shoot(idle_act, 0, *FRONT, "preview_idle_front.png")
shoot(run_act, 15, *SIDE, "preview_run_side.png")
shoot(run_act, 15, *FRONT, "preview_run_front.png")
shoot(jump_act, 0, *SIDE, "preview_jump_side.png")
shoot(slide_act, 10, *SIDE, "preview_slide_side.png")

arm_obj.animation_data.action = None

# --- export -----------------------------------------------------------------------

out = os.path.join(OUT_DIR, "runner.glb")
bpy.ops.export_scene.gltf(filepath=out, export_format='GLB')
print("EXPORTED", out, "actions:", [a.name for a in bpy.data.actions])
