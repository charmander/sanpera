"""Colors."""
import colorsys

from sanpera cimport c_api

from sanpera.exception cimport MagickException


# Scale between a fixed integral range and continuous 0-1:
#  0 ----- 1 ----- 2 ----- 3
# 0.0                     1.0
cdef double _quantum_to_double(c_api.Quantum value):
    return <double>value / c_api.QuantumRange

cdef c_api.Quantum _double_to_quantum(double value):
    return c_api.RoundToQuantum(value * c_api.QuantumRange)

cdef double _real_quantum_to_double(c_api.MagickRealType value):
    return <double>value / c_api.QuantumRange

cdef c_api.MagickRealType _double_to_real_quantum(double value):
    return value * c_api.QuantumRange

cdef float _clamp(float value):
    if value < 0.0:
        return 0.0
    elif value > 1.0:
        return 1.0
    else:
        return value


# TODO: handle more colorspaces, and arbitrary extra channels.
cdef class BaseColor:
    """Represents a color.

    Colors have some amount of color data (determined by the colorspace, but
    generally three channels' worth), an opacity, and an arbitrary number of
    other user-defined channels.  Channels' values are floats ranging from 0.0
    to 1.0.

    Particular colorspaces, and conversions between them, are implemented as
    subclasses of this class.

    All colors are immutable.  Convenience methods exist to make simple
    modifications, which will return a new color.
    """

    # TODO maybe i should just store the opacity like IM does, and only convert
    # when exposing to python  :|  and call it alpha.

    COLOR_WHEEL = [
        "red", "orange", "yellow", "chartreuse",
        "green", "seafoam", "cyan", "azure",
        "blue", "violet", "magenta", "rose",
    ]

    def __init__(self):
        raise TypeError("Can't instantiate BaseColor; use a subclass or other constructor")

    property description:
        def __get__(self):
            hslself = self.hsl()

            # Do lightness first, because it can short-circuit for near-black
            # and near-white
            l = hslself.lightness
            if l <= 0:
                return "black"
            elif l < 0.025:
                return "blackish"
            elif l < 0.1:
                shade = "very dark"
            elif l < 0.2:
                shade = "kinda dark"
            elif l < 0.3:
                shade = "dark"
            elif l < 0.4:
                shade = ""
            elif l < 0.6:
                shade = "bright"
            elif l < 0.7:
                shade = "powder"
            elif l < 0.8:
                shade = "pastel"
            elif l < 0.9:
                shade = "light"
            elif l < 0.975:
                shade = "pale"
            elif l < 1:
                return "whitish"
            else:
                return "white"

            # Saturation, another potential short-circuit, and another
            # adjective to be stuck on a color name
            s = hslself.saturation
            if s < 0.015:
                if shade:
                    return shade + " gray"
                else:
                    return "gray"
            elif s < 0.05:
                sat = "grayish"
            elif s < 0.15:
                sat = "very dim"
            elif s < 0.25:
                sat = "dim"
            elif s < 0.4:
                sat = "dusty"
            elif s < 0.6:
                sat = ""
            elif s < 0.75:
                sat = "deep"
            elif s < 0.85:
                sat = "bold"
            elif s < 0.95:
                sat = "intense"
            else:
                sat = "pure"

            # Compute the hue description.  Find the name from the list of
            # colors above, treating each as the *middle* of a section, and
            # treat colors roughly halfway between X and Y as "X-Y"
            h = hslself.hue
            colors = len(self.COLOR_WHEEL)
            wheel_position = (h * colors + 0.5 / colors) % colors
            wheel_index = int(wheel_position)

            hue = self.COLOR_WHEEL[wheel_index]
            if wheel_position - wheel_index > 0.5:
                hue += "-" + self.COLOR_WHEEL[(wheel_index + 1) % colors]

            color = hue
            if sat:
                color = sat + " " + color
            if shade:
                color = shade + " " + color

            # TODO opacity description?
            return color

    property opacity:
        def __get__(self):
            return self._opacity

    property extra_channels:
        def __get__(self):
            return self._extra_channels

    ### Conversions

    cpdef RGBColor rgb(self):
        raise NotImplementedError

    cpdef HSLColor hsl(self):
        raise NotImplementedError

    ### Constructors

    @classmethod
    def parse(type cls not None, bytes name not None):
        """Parse a color specification.

        Supports a whole buncha formats.
        """
        # TODO i don't like that this is tied to imagemagick's implementation.
        # would rather do most of the parsing myself, well-define what those
        # formats *are*, and use some other mechanism to expose the list of
        # builtin color names.  (maybe several lists, even.)
        # TODO also this always returns RGB anyway.

        cdef MagickException exc = MagickException()
        cdef c_api.MagickStatusType success
        cdef c_api.PixelPacket pixel

        success = c_api.QueryColorDatabase(name, &pixel, exc.ptr)
        exc.check()
        if not success:
            raise ValueError("Can't find a color named {0!r}".format(name))

        # TODO well ok clearly this isn't much of a classmethod
        print pixel
        print "pixel...",  _color_from_pixel(&pixel)
        return _color_from_pixel(&pixel)

    @classmethod
    def coerce(type cls not None, value not None):
        if isinstance(value, cls):
            # Already an object; do nothing
            return value

        # Probably a name; parse it
        return cls.parse(value)


    cdef _populate_pixel(self, c_api.PixelPacket* pixel):
        cdef RGBColor rgbself = self.rgb()
        pixel.red = _double_to_quantum(rgbself._red)
        pixel.green = _double_to_quantum(rgbself._green)
        pixel.blue = _double_to_quantum(rgbself._blue)
        pixel.opacity = _double_to_quantum(1.0 - rgbself._opacity)
        # TODO extra channels?

    cdef _populate_magick_pixel(self, c_api.MagickPixelPacket* pixel):
        cdef RGBColor rgbself = self.rgb()
        pixel.red = _double_to_quantum(rgbself._red)
        pixel.green = _double_to_quantum(rgbself._green)
        pixel.blue = _double_to_quantum(rgbself._blue)
        pixel.opacity = _double_to_quantum(1.0 - rgbself._opacity)
        # TODO extra channels?


    ### Special methods

    def __richcmp__(BaseColor left not None, BaseColor right not None, int op):
        if not (op == 0 or op == 3):
            return NotImplemented

        cdef RGBColor left_rgb = left.rgb()
        cdef RGBColor right_rgb = right.rgb()

        eq = (
            left_rgb._red == right_rgb._red
            and left_rgb._green == right_rgb._green
            and left_rgb._blue == right_rgb._blue
            and left_rgb._opacity == right_rgb._opacity
        )

        if op == 0:
            return eq
        elif op == 3:
            return not eq


cdef BaseColor _color_from_magick_pixel(c_api.MagickPixelPacket* pixel):
    # TODO this should also accept a colorspace and return the right class
    return RGBColor(
        _real_quantum_to_double(pixel.red),
        _real_quantum_to_double(pixel.green),
        _real_quantum_to_double(pixel.blue),
        1.0 - _real_quantum_to_double(pixel.opacity))

cdef BaseColor _color_from_pixel(c_api.PixelPacket* pixel):
    # TODO this should also accept a colorspace and return the right class
    return RGBColor(
        _quantum_to_double(pixel.red),
        _quantum_to_double(pixel.green),
        _quantum_to_double(pixel.blue),
        1.0 - _quantum_to_double(pixel.opacity))



cdef class RGBColor(BaseColor):
    def __init__(self, double red, double green, double blue, double opacity = 1.0):
        self._red = red
        self._green = green
        self._blue = blue
        self._opacity = opacity
        self._extra_channels = ()

    def __repr__(self):
        return "<RGBColor {0:0.3f} red, {1:0.3f} green, {2:0.3f} blue ({3}) {4:0.1f}% opacity>".format(
            self._red, self._green, self._blue, self.description, self._opacity * 100)

    def __richcmp__(self, other, int op):
        if op not in (2, 3):
            # Only support == and !=
            return NotImplemented

        if not isinstance(self, RGBColor) or not isinstance(other, RGBColor):
            return NotImplemented

        cdef RGBColor left = self
        cdef RGBColor right = other

        # TODO floating-point problems ahoy
        # TODO 0% opacity colors should always be identical
        eq = (left._red == right._red
            and left._green == right._green
            and left._blue == right._blue
            and left._opacity == right._opacity
            and left._extra_channels == right._extra_channels
        )

        if op == 2:
            # ==
            return eq
        elif op == 3:
            # !=
            return not eq

    def __mul__(self, other):
        # TODO does this semantic make sense?  it's just what IM's fx syntax
        # does
        # TODO this is only defined for RGB.  move it to base and just make it
        # convert to RGB, then back to the original class...?
        cdef RGBColor color
        cdef float factor

        if isinstance(self, RGBColor):
            color = self
            factor = other
        else:
            factor = self
            color = other

        # TODO extra channels
        return RGBColor(
            color._red * factor,
            color._green * factor,
            color._blue * factor,
            color._opacity)

    def clamped(self):
        # TODO every color type
        # TODO extra channels (clamp them??)
        return RGBColor(
            _clamp(self._red),
            _clamp(self._green),
            _clamp(self._blue),
            _clamp(self._opacity))

    property red:
        def __get__(self):
            return self._red

    property green:
        def __get__(self):
            return self._green

    property blue:
        def __get__(self):
            return self._blue

    cpdef RGBColor rgb(self):
        return self

    cpdef HSLColor hsl(self):
        # TODO perhaps rewrite this manually for speed
        hue, light, sat = colorsys.rgb_to_hls(self._red, self._green, self._blue)
        # TODO extra channels
        return HSLColor(hue, sat, light, self._opacity)

cdef class HSLColor(BaseColor):
    def __init__(self, double hue, double saturation, double lightness, double opacity = 1.0):
        if hue == 1.0:
            hue = 0.0

        self._hue = hue
        self._saturation = saturation
        self._lightness = lightness
        self._opacity = opacity
        self._extra_channels = ()

    def __repr__(self):
        return "<HSLColor {0:0.3f} hue, {1:0.3f} sat, {2:0.3f} light ({3}) {4:0.1f}% opacity>".format(
            self._hue, self._saturation, self._lightness, self.description, self._opacity * 100)

    property hue:
        def __get__(self):
            return self._hue

    property saturation:
        def __get__(self):
            return self._saturation

    property lightness:
        def __get__(self):
            return self._lightness

    cpdef HSLColor hsl(self):
        return self
