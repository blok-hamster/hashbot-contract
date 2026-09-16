# Trait names

What a buyer sees on OpenSea. The left column is the file and never appears anywhere;
the right column is the name. To change a name, edit `build/trait-names.json`
and run `node scripts/make-names.mjs` again.

A line marked `<-- shares a name` is one of 0 names given to more than one trait.
Sometimes that is right, because the two really are the same object in the same
colour. Sometimes it is not. The number is how far apart the pixels are, which
sorts them for your attention but does not decide: a recoloured confetti scores
19 and is still confetti, a scarf with different trim scores 3 and is a different
trait. These need eyes, and the contact sheets in `build/sheets/` are how to use
them.

## Background

```
  bg 7.png          Abyss
  glow04-a.png      Amber Core
  BG 18.png         Aurora
  bg 4.png          Blood Moon
  BG 17.png         Blue Giant
  BG 13.png         Cold Fusion
  glow02-a.png      Crimson Pulse
  bg 5.png          Deep Space
  glow06-a.png      Dying Star
  glow03-a.png      Emerald Core
  glow08-a.png      Jade Drift
  glow07-a.png      Magenta Drift
  bg 6.png          Nebula
  bg 3.png          Rust Haze
  BG 14.png         Solar Flare
  BG 15.png         Supernova
  glow01-a.png      Toxic Bloom
  glow05-a.png      Violet Surge
```

## Chassis

```
  skins4-a.png      Amber Chassis
  skins3-b.png      Bright Cyan Chassis
  skins3.png        Bright Gold Chassis
  skins3-a.png      Bright Jade Chassis
  skins3-d.png      Bright Rose Chassis
  skins3-c.png      Bright Violet Chassis
  skin 8.png        Crimson Chassis
  skins4-b.png      Cyan Chassis
  skin 10.png       Deep Cobalt Chassis
  skins1.png        Deep Crimson Chassis
  skin 11-d.png     Deep Indigo Chassis
  skin 11-b.png     Deep Jade Chassis
  skins1-a.png      Deep Lime Chassis
  skin 11.png       Deep Magenta Chassis
  skin 10-b.png     Deep Rust Chassis
  skin 11-c.png     Deep Teal Chassis
  skins4-c.png      Jade Chassis
  skins2.png        Pale Amber Chassis
  skins2-b.png      Pale Cyan Chassis
  skins2-c.png      Pale Jade Chassis
  skins2-d.png      Pale Violet Chassis
  skin 9-a.png      Rose Chassis
  skin 9.png        Violet Chassis
```

## Scene

```
  DOWN 9.png        Bone Arc Bloom
  Down 11-b.png     Bright Cobalt Arc Bloom
  down 7.png        Bright Cobalt Smoulder
  down 6.png        Bright Cobalt Wildfire
  DOWN 10.png       Bright Crimson Arc Bloom
  down 7-b.png      Bright Crimson Smoulder
  down 6-b.png      Bright Crimson Wildfire
  Down 11.png       Bright Gold Arc Bloom
  down 7-c.png      Bright Gold Smoulder
  down 6-c.png      Bright Gold Wildfire
  Down 11-a.png     Bright Jade Arc Bloom
  down 7-d.png      Bright Jade Smoulder
  down 6-d.png      Bright Jade Wildfire
  DOWN 10-a.png     Bright Lime Arc Bloom
  DOWN 10-d.png     Bright Magenta Arc Bloom
  down 3.png        Bright Prism Confetti
  Down 11-c.png     Bright Violet Arc Bloom
  down 7-a.png      Bright Violet Smoulder
  down 6-a.png      Bright Violet Wildfire
  down 4-d.png      Cobalt Equaliser
  down 12-a.png     Cyan Equaliser
  down 4-b.png      Gold Equaliser
  down 12.png       Jade Equaliser
  down 5-c.png      Pale Amber Crystal City
  down 2.png        Pale Cobalt Marlin
  DOWN 8.png        Pale Cyan Arc Bloom
  down 5.png        Pale Cyan Crystal City
  DOWN 8-c.png      Pale Gold Arc Bloom
  down 2-c.png      Pale Gold Marlin
  down 5-a.png      Pale Indigo Crystal City
  DOWN 8-d.png      Pale Jade Arc Bloom
  down 5-d.png      Pale Jade Crystal City
  down 2-d.png      Pale Jade Marlin
  DOWN 8-b.png      Pale Rose Arc Bloom
  down 5-b.png      Pale Rose Crystal City
  down 2-b.png      Pale Rose Marlin
  DOWN 8-a.png      Pale Violet Arc Bloom
  down 2-a.png      Pale Violet Marlin
  down 4-a.png      Rose Equaliser
  down 4.png        Violet Equaliser
```

## Headpiece

```
  head21-c.png      Amber Spark
  head 4.png        Bone Spark
  head20-c.png      Bright Amber Arc Halo
  head18-c.png      Bright Cobalt Arc Halo
  head 12-c.png     Bright Cobalt Valkyrie Wings
  head18.png        Bright Crimson Arc Halo
  head 12.png       Bright Crimson Valkyrie Wings
  head20.png        Bright Cyan Arc Halo
  head19.png        Bright Gold Arc Halo
  head20-a.png      Bright Indigo Arc Halo
  head20-d.png      Bright Jade Arc Halo
  head 12-b.png     Bright Jade Valkyrie Wings
  head18-a.png      Bright Lime Arc Halo
  head 12-a.png     Bright Lime Valkyrie Wings
  head18-d.png      Bright Magenta Arc Halo
  head 12-d.png     Bright Magenta Valkyrie Wings
  head20-b.png      Bright Rose Arc Halo
  head19-c.png      Bright Violet Arc Halo
  head 1-a.png      Bronze Arc Halo
  head 7-c.png      Cobalt Antennae
  head 23.png       Cobalt Halo
  head22-b.png      Cobalt Spark
  head 7.png        Crimson Antennae
  head 8.png        Crimson Halo
  head22-d.png      Crimson Spark
  head21.png        Cyan Spark
  head 6.png        Deep Amber Ivy
  head16-a.png      Deep Amber Sentry Orb
  head 2.png        Deep Crimson Sentry Orb
  head 6-b.png      Deep Cyan Ivy
  head16.png        Deep Cyan Sentry Orb
  head 5-d.png      Deep Gold Ivy
  head 6-c.png      Deep Indigo Ivy
  head 5.png        Deep Jade Ivy
  head 2-c.png      Deep Jade Sentry Orb
  head17-d.png      Deep Mauve Halo
  head 9-d.png      Deep Mauve Wide Halo
  head17-c.png      Deep Moss Halo
  head 9-c.png      Deep Moss Wide Halo
  head 6-d.png      Deep Rose Ivy
  head17-b.png      Deep Steel Halo
  head 9-b.png      Deep Steel Wide Halo
  head17-a.png      Deep Umber Halo
  head 9-a.png      Deep Umber Wide Halo
  head 5-b.png      Deep Violet Ivy
  head16-d.png      Deep Violet Sentry Orb
  head 23-c.png     Gold Halo
  head22.png        Gold Spark
  head21-a.png      Indigo Spark
  head 7-b.png      Jade Antennae
  head 23-d.png     Jade Halo
  head21-d.png      Jade Spark
  head 7-a.png      Lime Antennae
  head 8-a.png      Lime Halo
  head 7-d.png      Magenta Antennae
  head 8-d.png      Magenta Halo
  head 1-d.png      Mauve Arc Halo
  head 1-c.png      Moss Arc Halo
  head 3.png        None
  head 1.png        Onyx Arc Halo
  head 14-b.png     Pale Cobalt Valkyrie Wings
  head 14-d.png     Pale Crimson Valkyrie Wings
  head 11.png       Pale Cyan Valkyrie Wings
  head 15-d.png     Pale Gold Valkyrie Wings
  head 15.png       Pale Jade Valkyrie Wings
  head 14.png       Pale Lime Valkyrie Wings
  head 14-c.png     Pale Magenta Valkyrie Wings
  head 11-b.png     Pale Rose Valkyrie Wings
  head 11-a.png     Pale Violet Valkyrie Wings
  head21-b.png      Rose Spark
  head 1-b.png      Steel Arc Halo
  head 8-b.png      Teal Halo
  head 23-a.png     Violet Halo
  head22-c.png      Violet Spark
```

## Visor

```
  eye 16-a.png      Amber Data Visor
  eye 5.png         Amber Pizza Day
  EYE 10-c.png      Bright Amber Circuit Visor
  eye 13-a.png      Bright Amber Diamond Visor
  eye 15-a.png      Bright Amber Power Visor
  eye 2.png         Bright Cobalt Beam
  eye11-c.png       Bright Cobalt Circuit Visor
  eye 13.png        Bright Cobalt Diamond Visor
  eye 8-b.png       Bright Cobalt Honeycomb
  eye13-c.png       Bright Cobalt Pepe Hologram
  eye1.png          Bright Crimson Beam
  eye11.png         Bright Crimson Circuit Visor
  eye 8-d.png       Bright Crimson Honeycomb
  eye13.png         Bright Crimson Pepe Hologram
  eye 15.png        Bright Crimson Power Visor
  EYE 10.png        Bright Cyan Circuit Visor
  eye 13-b.png      Bright Cyan Diamond Visor
  eye 15-b.png      Bright Cyan Power Visor
  eye 2-c.png       Bright Gold Beam
  eye 8.png         Bright Gold Honeycomb
  eye13-a.png       Bright Gold Pepe Hologram
  EYE 10-a.png      Bright Indigo Circuit Visor
  eye 2-d.png       Bright Jade Beam
  EYE 10-d.png      Bright Jade Circuit Visor
  eye 13-c.png      Bright Jade Diamond Visor
  eye 8-a.png       Bright Jade Honeycomb
  eye13-b.png       Bright Jade Pepe Hologram
  eye 15-c.png      Bright Jade Power Visor
  eye1-a.png        Bright Lime Beam
  eye11-a.png       Bright Lime Circuit Visor
  eye1-d.png        Bright Magenta Beam
  eye11-d.png       Bright Magenta Circuit Visor
  EYE 10-b.png      Bright Rose Circuit Visor
  eye 2-a.png       Bright Violet Beam
  eye12.png         Bright Violet Circuit Visor
  eye 13-d.png      Bright Violet Diamond Visor
  eye 8-c.png       Bright Violet Honeycomb
  eye13-d.png       Bright Violet Pepe Hologram
  eye 15-d.png      Bright Violet Power Visor
  eye 16-b.png      Cyan Data Visor
  mouth 9.png       Cyan Goggles
  eye 5-b.png       Cyan Pizza Day
  eye15-a.png       Deep Amber Readout Visor
  eye15-b.png       Deep Cyan Readout Visor
  eye15.png         Deep Jade Readout Visor
  eye15-e.png       Deep Lime Readout Visor
  eye15-d.png       Deep Violet Readout Visor
  mouth 9-c.png     Gold Goggles
  eye 5-c.png       Indigo Pizza Day
  eye 16.png        Jade Data Visor
  mouth 9-d.png     Jade Goggles
  eye 5-a.png       Jade Pizza Day
  eye14-c.png       Pale Cobalt Skull Hologram
  eye14.png         Pale Crimson Skull Hologram
  eye 3.png         Pale Cyan Bitcoin Hologram
  EYE 11.png        Pale Cyan Globe Hologram
  eye 4.png         Pale Cyan Pepe Hologram
  eye 12.png        Pale Cyan Skull Hologram
  eye 3-c.png       Pale Gold Bitcoin Hologram
  EYE 11-c.png      Pale Gold Globe Hologram
  eye 4-c.png       Pale Gold Pepe Hologram
  eye14-a.png       Pale Gold Skull Hologram
  eye 3-d.png       Pale Jade Bitcoin Hologram
  EYE 11-d.png      Pale Jade Globe Hologram
  eye 4-d.png       Pale Jade Pepe Hologram
  eye14-b.png       Pale Jade Skull Hologram
  eye14-d.png       Pale Magenta Skull Hologram
  eye 3-b.png       Pale Rose Bitcoin Hologram
  EYE 11-b.png      Pale Rose Globe Hologram
  eye 4-b.png       Pale Rose Pepe Hologram
  eye 12-b.png      Pale Rose Skull Hologram
  eye 3-a.png       Pale Violet Bitcoin Hologram
  EYE 11-a.png      Pale Violet Globe Hologram
  eye 4-a.png       Pale Violet Pepe Hologram
  eye 12-a.png      Pale Violet Skull Hologram
  mouth 9-b.png     Rose Goggles
  eye 5-d.png       Rose Pizza Day
  eye 16-d.png      Violet Data Visor
  mouth 9-a.png     Violet Goggles
```

## Mask

```
  mouth 1-a.png     Amber Respirator
  mouth 9-c.png     Bright Amber Scarf
  mouth 7-a.png     Bright Bronze Fanged Jaw
  mouth e-a.png     Bright Bronze Respirator
  mouth10-b.png     Bright Cobalt Scarf
  mouth10-d.png     Bright Crimson Scarf
  mouth 9.png       Bright Cyan Scarf
  mouth10.png       Bright Gold Scarf
  mouth 9-a.png     Bright Indigo Scarf
  mouth 7-c.png     Bright Jade Fanged Jaw
  mouth 9-d.png     Bright Jade Scarf
  mouth 7-d.png     Bright Mauve Fanged Jaw
  mouth e-d.png     Bright Mauve Respirator
  mouth e-c.png     Bright Moss Respirator
  mouth 9-b.png     Bright Rose Scarf
  mouth 7-b.png     Bright Steel Fanged Jaw
  mouth e-b.png     Bright Steel Respirator
  mouth10-c.png     Bright Violet Scarf
  mouth 2.png       Crimson Respirator
  mouth13-b.png     Cyan Respirator
  mouth11-a.png     Deep Bronze Scarf
  mouth14.png       Deep Cobalt Fanged Jaw
  mouth 6.png       Deep Crimson Fanged Jaw
  mouth14-d.png     Deep Jade Fanged Jaw
  mouth14-c.png     Deep Lime Fanged Jaw
  mouth 6-d.png     Deep Magenta Fanged Jaw
  mouth11-c.png     Deep Moss Scarf
  mouth14-a.png     Deep Violet Fanged Jaw
  mouth13.png       Gold Respirator
  mouth12.png       Indigo Respirator
  mouth 1.png       Jade Respirator
  mouth 4.png       None
  mouth e.png       Obsidian Respirator
  mouth 7.png       Onyx Fanged Jaw
  mouth11.png       Onyx Scarf
  mouth13-a.png     Rust Respirator
  mouth13-d.png     Violet Respirator
```

