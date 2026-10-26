[Variables]
; ============================================
; App Audio Widget - Configuration
; ============================================

; Seconds between snapshots (default: 2)
RefreshInterval=2

; Seconds an app stays listed after it goes quiet, so pauses between
; sentences or songs do not make rows flicker
HoldSeconds=6

; Path to PowerShell script (relative to @Resources folder)
ScriptPath=#@#Scripts\Get-AppAudio.ps1
FocusScriptPath=#@#Scripts\Focus-App.ps1

; Rows the skin has room for. The script is told the same number;
; raising it also needs more [SlotN] blocks in AppAudio.ini.
MaxSlots=6

; ============================================
; Scale
; ============================================
; Master zoom for the whole widget.
; 1 = the original size, 2 = double, 1.5 = halfway. Decimals are fine.
; Every dimension, offset and font size is multiplied by this.
; Change it and right-click the skin -> Refresh.
Scale=2

; ============================================
; Colors (RGBA format: RRR,GGG,BBB,AAA)
; Same palette as the AI Usage widget
; ============================================

; Background
BackgroundColor=30,30,35,240

; Text colors
TextColor=220,220,225,255
TextColorDim=140,140,150,255
TextColorBright=255,255,255,255

; Status colors
NormalColor=130,180,130,255
WarningColor=220,160,60,255
CriticalColor=220,80,80,255
HighlightColor=100,200,255,255

; Bar colors
BarBackgroundColor=50,50,55,255
BarNormalColor=100,180,255,255
BarQuietColor=90,90,100,255
BarMutedColor=70,70,78,255

; Row click target: idle has to keep 1 of alpha, or the row stops taking clicks
RowIdleColor=0,0,0,1
RowHoverColor=255,255,255,14

; Accent/border color
AccentColor=100,100,110,255

; Section heading color
SectionColor=150,150,165,255

; ============================================
; Dimensions - base values, multiplied by #Scale#
; ============================================

; Widget size. The height follows the number of rows.
WidgetWidth=(280*#Scale#)
WidgetPadding=(15*#Scale#)
CornerRadius=(8*#Scale#)

; Bar dimensions
BarHeight=(8*#Scale#)
BarWidth=(250*#Scale#)

; Vertical rhythm
HeaderY=(12*#Scale#)
SectionY=(42*#Scale#)
ListY=(62*#Scale#)
SlotHeight=(56*#Scale#)
BarGap=(4*#Scale#)
TextGap=(3*#Scale#)
BottomPadding=(8*#Scale#)
GearOffset=(70*#Scale#)
HitInset=(4*#Scale#)
StatusDotOffset=(5*#Scale#)

; Horizontal layout
ValueColumn=(48*#Scale#)
DetailLabelWidth=(44*#Scale#)

; Horizontal gaps between inline text runs
GapTiny=(1*#Scale#)
GapWide=(5*#Scale#)
GapLabel=(6*#Scale#)

; Font settings
FontFace=Segoe UI
FontSizeIcon=(14*#Scale#)
FontSizeTitle=(12*#Scale#)
FontSizeLabel=(10*#Scale#)
FontSizeSmall=(9*#Scale#)
FontSizeSection=(8*#Scale#)
SectionHeight=(12*#Scale#)
