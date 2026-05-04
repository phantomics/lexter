;;;; CP437 to Unicode mapping table
;;;;
;;;; Maps DOS Code Page 437 byte values (0-255) to Unicode codepoints.
;;;; Bytes 0x00-0x7F map to ASCII (with some special glyphs for 0x00-0x1F).
;;;; Bytes 0x80-0xFF contain box-drawing, accented characters, etc.

(in-package #:lexter/telnet)

(defparameter +cp437-to-unicode+
  (make-array 256
              :element-type '(unsigned-byte 32)
              :initial-contents
              '(;; 0x00-0x0F: Control characters / special glyphs
                #x0000   ; 00 NUL (displayed as space)
                #x263A   ; 01 White smiling face
                #x263B   ; 02 Black smiling face
                #x2665   ; 03 Black heart suit
                #x2666   ; 04 Black diamond suit
                #x2663   ; 05 Black club suit
                #x2660   ; 06 Black spade suit
                #x2022   ; 07 Bullet
                #x25D8   ; 08 Inverse bullet
                #x25CB   ; 09 White circle
                #x25D9   ; 0A Inverse white circle
                #x2642   ; 0B Male sign
                #x2640   ; 0C Female sign
                #x266A   ; 0D Eighth note
                #x266B   ; 0E Beamed eighth notes
                #x263C   ; 0F Sun
                ;; 0x10-0x1F: More special glyphs
                #x25BA   ; 10 Black right-pointing pointer
                #x25C4   ; 11 Black left-pointing pointer
                #x2195   ; 12 Up down arrow
                #x203C   ; 13 Double exclamation mark
                #x00B6   ; 14 Pilcrow sign
                #x00A7   ; 15 Section sign
                #x25AC   ; 16 Black rectangle
                #x21A8   ; 17 Up down arrow with base
                #x2191   ; 18 Upwards arrow
                #x2193   ; 19 Downwards arrow
                #x2192   ; 1A Rightwards arrow
                #x2190   ; 1B Leftwards arrow
                #x221F   ; 1C Right angle
                #x2194   ; 1D Left right arrow
                #x25B2   ; 1E Black up-pointing triangle
                #x25BC   ; 1F Black down-pointing triangle
                ;; 0x20-0x7E: Standard ASCII
                #x0020 #x0021 #x0022 #x0023 #x0024 #x0025 #x0026 #x0027  ; 20-27
                #x0028 #x0029 #x002A #x002B #x002C #x002D #x002E #x002F  ; 28-2F
                #x0030 #x0031 #x0032 #x0033 #x0034 #x0035 #x0036 #x0037  ; 30-37
                #x0038 #x0039 #x003A #x003B #x003C #x003D #x003E #x003F  ; 38-3F
                #x0040 #x0041 #x0042 #x0043 #x0044 #x0045 #x0046 #x0047  ; 40-47
                #x0048 #x0049 #x004A #x004B #x004C #x004D #x004E #x004F  ; 48-4F
                #x0050 #x0051 #x0052 #x0053 #x0054 #x0055 #x0056 #x0057  ; 50-57
                #x0058 #x0059 #x005A #x005B #x005C #x005D #x005E #x005F  ; 58-5F
                #x0060 #x0061 #x0062 #x0063 #x0064 #x0065 #x0066 #x0067  ; 60-67
                #x0068 #x0069 #x006A #x006B #x006C #x006D #x006E #x006F  ; 68-6F
                #x0070 #x0071 #x0072 #x0073 #x0074 #x0075 #x0076 #x0077  ; 70-77
                #x0078 #x0079 #x007A #x007B #x007C #x007D #x007E         ; 78-7E
                ;; 0x7F: Delete / House
                #x2302   ; 7F House
                ;; 0x80-0x8F: Accented characters
                #x00C7   ; 80 Latin capital C with cedilla
                #x00FC   ; 81 Latin small u with diaeresis
                #x00E9   ; 82 Latin small e with acute
                #x00E2   ; 83 Latin small a with circumflex
                #x00E4   ; 84 Latin small a with diaeresis
                #x00E0   ; 85 Latin small a with grave
                #x00E5   ; 86 Latin small a with ring above
                #x00E7   ; 87 Latin small c with cedilla
                #x00EA   ; 88 Latin small e with circumflex
                #x00EB   ; 89 Latin small e with diaeresis
                #x00E8   ; 8A Latin small e with grave
                #x00EF   ; 8B Latin small i with diaeresis
                #x00EE   ; 8C Latin small i with circumflex
                #x00EC   ; 8D Latin small i with grave
                #x00C4   ; 8E Latin capital A with diaeresis
                #x00C5   ; 8F Latin capital A with ring above
                ;; 0x90-0x9F: More accented characters
                #x00C9   ; 90 Latin capital E with acute
                #x00E6   ; 91 Latin small ae
                #x00C6   ; 92 Latin capital AE
                #x00F4   ; 93 Latin small o with circumflex
                #x00F6   ; 94 Latin small o with diaeresis
                #x00F2   ; 95 Latin small o with grave
                #x00FB   ; 96 Latin small u with circumflex
                #x00F9   ; 97 Latin small u with grave
                #x00FF   ; 98 Latin small y with diaeresis
                #x00D6   ; 99 Latin capital O with diaeresis
                #x00DC   ; 9A Latin capital U with diaeresis
                #x00A2   ; 9B Cent sign
                #x00A3   ; 9C Pound sign
                #x00A5   ; 9D Yen sign
                #x20A7   ; 9E Peseta sign
                #x0192   ; 9F Latin small f with hook
                ;; 0xA0-0xAF: More accented and special
                #x00E1   ; A0 Latin small a with acute
                #x00ED   ; A1 Latin small i with acute
                #x00F3   ; A2 Latin small o with acute
                #x00FA   ; A3 Latin small u with acute
                #x00F1   ; A4 Latin small n with tilde
                #x00D1   ; A5 Latin capital N with tilde
                #x00AA   ; A6 Feminine ordinal indicator
                #x00BA   ; A7 Masculine ordinal indicator
                #x00BF   ; A8 Inverted question mark
                #x2310   ; A9 Reversed not sign
                #x00AC   ; AA Not sign
                #x00BD   ; AB Vulgar fraction one half
                #x00BC   ; AC Vulgar fraction one quarter
                #x00A1   ; AD Inverted exclamation mark
                #x00AB   ; AE Left-pointing double angle quotation mark
                #x00BB   ; AF Right-pointing double angle quotation mark
                ;; 0xB0-0xBF: Box drawing light
                #x2591   ; B0 Light shade
                #x2592   ; B1 Medium shade
                #x2593   ; B2 Dark shade
                #x2502   ; B3 Box drawings light vertical
                #x2524   ; B4 Box drawings light vertical and left
                #x2561   ; B5 Box drawings vertical single and left double
                #x2562   ; B6 Box drawings vertical double and left single
                #x2556   ; B7 Box drawings down double and left single
                #x2555   ; B8 Box drawings down single and left double
                #x2563   ; B9 Box drawings double vertical and left
                #x2551   ; BA Box drawings double vertical
                #x2557   ; BB Box drawings double down and left
                #x255D   ; BC Box drawings double up and left
                #x255C   ; BD Box drawings up double and left single
                #x255B   ; BE Box drawings up single and left double
                #x2510   ; BF Box drawings light down and left
                ;; 0xC0-0xCF: Box drawing
                #x2514   ; C0 Box drawings light up and right
                #x2534   ; C1 Box drawings light up and horizontal
                #x252C   ; C2 Box drawings light down and horizontal
                #x251C   ; C3 Box drawings light vertical and right
                #x2500   ; C4 Box drawings light horizontal
                #x253C   ; C5 Box drawings light vertical and horizontal
                #x255E   ; C6 Box drawings vertical single and right double
                #x255F   ; C7 Box drawings vertical double and right single
                #x255A   ; C8 Box drawings double up and right
                #x2554   ; C9 Box drawings double down and right
                #x2569   ; CA Box drawings double up and horizontal
                #x2566   ; CB Box drawings double down and horizontal
                #x2560   ; CC Box drawings double vertical and right
                #x2550   ; CD Box drawings double horizontal
                #x256C   ; CE Box drawings double vertical and horizontal
                #x2567   ; CF Box drawings up single and horizontal double
                ;; 0xD0-0xDF: More box drawing
                #x2568   ; D0 Box drawings up double and horizontal single
                #x2564   ; D1 Box drawings down single and horizontal double
                #x2565   ; D2 Box drawings down double and horizontal single
                #x2559   ; D3 Box drawings up double and right single
                #x2558   ; D4 Box drawings up single and right double
                #x2552   ; D5 Box drawings down single and right double
                #x2553   ; D6 Box drawings down double and right single
                #x256B   ; D7 Box drawings vertical double and horizontal single
                #x256A   ; D8 Box drawings vertical single and horizontal double
                #x2518   ; D9 Box drawings light up and left
                #x250C   ; DA Box drawings light down and right
                #x2588   ; DB Full block
                #x2584   ; DC Lower half block
                #x258C   ; DD Left half block
                #x2590   ; DE Right half block
                #x2580   ; DF Upper half block
                ;; 0xE0-0xEF: Greek letters
                #x03B1   ; E0 Greek small letter alpha
                #x00DF   ; E1 Latin small letter sharp s
                #x0393   ; E2 Greek capital letter gamma
                #x03C0   ; E3 Greek small letter pi
                #x03A3   ; E4 Greek capital letter sigma
                #x03C3   ; E5 Greek small letter sigma
                #x00B5   ; E6 Micro sign
                #x03C4   ; E7 Greek small letter tau
                #x03A6   ; E8 Greek capital letter phi
                #x0398   ; E9 Greek capital letter theta
                #x03A9   ; EA Greek capital letter omega
                #x03B4   ; EB Greek small letter delta
                #x221E   ; EC Infinity
                #x03C6   ; ED Greek small letter phi
                #x03B5   ; EE Greek small letter epsilon
                #x2229   ; EF Intersection
                ;; 0xF0-0xFF: Math symbols and final characters
                #x2261   ; F0 Identical to
                #x00B1   ; F1 Plus-minus sign
                #x2265   ; F2 Greater-than or equal to
                #x2264   ; F3 Less-than or equal to
                #x2320   ; F4 Top half integral
                #x2321   ; F5 Bottom half integral
                #x00F7   ; F6 Division sign
                #x2248   ; F7 Almost equal to
                #x00B0   ; F8 Degree sign
                #x2219   ; F9 Bullet operator
                #x00B7   ; FA Middle dot
                #x221A   ; FB Square root
                #x207F   ; FC Superscript latin small letter n
                #x00B2   ; FD Superscript two
                #x25A0   ; FE Black square
                #x00A0   ; FF No-break space
                ))
  "Maps CP437 byte values (0-255) to Unicode codepoints.")
