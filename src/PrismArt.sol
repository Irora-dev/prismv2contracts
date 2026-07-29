// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LibString} from "solady/src/utils/LibString.sol";
import {Base64}    from "solady/src/utils/Base64.sol";

/// @notice one v4 pool. five thousand facets.
/// @author 0xsolazy (https://github.com/0xsolazy/)
/// @custom:website Prism (https://prism.0xsolazy.eth.limo/)
/// @custom:x Prism (https://x.com/prism_lp/)
library PrismArt {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           PUBLIC                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Returns the full `data:application/json;base64,...` ERC-721 token URI.
    function tokenURI(uint256 tokenId, bytes32 seed) internal pure returns (string memory) {
        string memory svg    = _renderSVG(seed);
        string memory traits = _renderTraits(seed);
        string memory json = string(
            abi.encodePacked(
                '{"name":"Prism #', LibString.toString(tokenId),
                '","description":"A facet of the Prism v4 liquidity pool. ',
                'Each NFT is a 1/5000 share, rendered fully on-chain.",',
                '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '",',
                '"attributes":', traits,
                '}'
            )
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    /// @dev Raw SVG string for the given seed. Useful for off-chain preview.
    function renderSVG(bytes32 seed) internal pure returns (string memory) {
        return _renderSVG(seed);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          INTERNAL                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _renderSVG(bytes32 seed) private pure returns (string memory) {
        uint16  hue        = uint16(uint256(uint8(seed[0])) * 360 / 256);
        uint16  nMilli     = 1450 + uint16(uint8(seed[1])) * 200 / 255;        // 1.450..1.650
        uint16  beamEndY   = 150 + uint16(uint8(seed[2])) % 80;                // 150..229
        uint16  wavelength = 410 + uint16(uint8(seed[3])) % 290;               // 410..665 nm (uint8 % 290 == uint8)
        uint8   accent     = uint8(seed[4]);
        return string(
            abi.encodePacked(
                // `style="background:#000"` alone is not enough. `background` is not an SVG
                // presentation attribute — it paints only because browsers apply CSS to the <svg>
                // root. Standalone rasterizers (resvg, librsvg, ImageMagick) ignore it, and SVG
                // sanitizers routinely strip `style=` outright since inline CSS is an XSS vector.
                // Nearly every mark below is #fff, so losing the background renders the art white on
                // transparent — invisible on any light surface. An explicit <rect> is the only
                // portable background; explicit width/height stop rasterizers falling back to a
                // 100x100 intrinsic size. The style is kept too: harmless, and in browsers it also
                // covers the bleed outside the viewBox.
                '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"',
                ' viewBox="0 0 400 400" style="background:#000">',
                '<rect width="400" height="400" fill="#000"/>',
                _grid(),
                _cornerMarks(),
                _prismWire(),
                _incomingBeam(),
                _refractedBeam(hue, beamEndY),
                _refractionAnnotations(accent),
                _titleBlock(seed, nMilli, wavelength),
                '</svg>'
            )
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ELEMENTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Faint background grid, 50px spacing.
    function _grid() private pure returns (string memory) {
        return
            '<g stroke="#fff" stroke-width="0.5" opacity="0.05">'
            '<line x1="0" y1="50" x2="400" y2="50"/>'
            '<line x1="0" y1="100" x2="400" y2="100"/>'
            '<line x1="0" y1="150" x2="400" y2="150"/>'
            '<line x1="0" y1="200" x2="400" y2="200"/>'
            '<line x1="0" y1="250" x2="400" y2="250"/>'
            '<line x1="0" y1="300" x2="400" y2="300"/>'
            '<line x1="0" y1="350" x2="400" y2="350"/>'
            '<line x1="50" y1="0" x2="50" y2="400"/>'
            '<line x1="100" y1="0" x2="100" y2="400"/>'
            '<line x1="150" y1="0" x2="150" y2="400"/>'
            '<line x1="200" y1="0" x2="200" y2="400"/>'
            '<line x1="250" y1="0" x2="250" y2="400"/>'
            '<line x1="300" y1="0" x2="300" y2="400"/>'
            '<line x1="350" y1="0" x2="350" y2="400"/>'
            '</g>';
    }

    /// @dev Viewport crop marks at the four corners.
    function _cornerMarks() private pure returns (string memory) {
        return
            '<g stroke="#fff" stroke-width="1" fill="none" opacity="0.45">'
            '<path d="M10,30 L10,10 L30,10"/>'
            '<path d="M370,10 L390,10 L390,30"/>'
            '<path d="M390,370 L390,390 L370,390"/>'
            '<path d="M30,390 L10,390 L10,370"/>'
            '</g>';
    }

    /// @dev Prism as isometric wireframe: solid front face + dashed back face.
    function _prismWire() private pure returns (string memory) {
        return
            // back face, dashed (suggests depth)
            '<polygon points="220,100 330,280 110,280" fill="none" stroke="#fff" stroke-width="0.5" stroke-dasharray="3,2" opacity="0.4"/>'
            // edges from front face vertices to back face vertices
            '<line x1="200" y1="110" x2="220" y2="100" stroke="#fff" stroke-width="0.5" opacity="0.45"/>'
            '<line x1="310" y1="290" x2="330" y2="280" stroke="#fff" stroke-width="0.5" opacity="0.45"/>'
            '<line x1="90"  y1="290" x2="110" y2="280" stroke="#fff" stroke-width="0.5" opacity="0.45"/>'
            // front face, solid prominent
            '<polygon points="200,110 310,290 90,290" fill="none" stroke="#fff" stroke-width="1.5"/>'
            // small vertex dots
            '<circle cx="200" cy="110" r="2" fill="#fff"/>'
            '<circle cx="310" cy="290" r="2" fill="#fff"/>'
            '<circle cx="90"  cy="290" r="2" fill="#fff"/>';
    }

    /// @dev Incoming white beam with measurement ticks.
    function _incomingBeam() private pure returns (string memory) {
        return
            '<line x1="20" y1="220" x2="155" y2="250" stroke="#fff" stroke-width="1"/>'
            '<g stroke="#fff" stroke-width="0.5" opacity="0.6">'
            '<line x1="50"  y1="223" x2="50"  y2="233"/>'
            '<line x1="85"  y1="231" x2="85"  y2="241"/>'
            '<line x1="120" y1="239" x2="120" y2="249"/>'
            '</g>';
    }

    /// @dev Single refracted beam in the seed's hue — only color in the whole composition.
    function _refractedBeam(uint16 hue, uint16 endY) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<line x1="245" y1="250" x2="380" y2="', LibString.toString(endY),
                '" stroke="hsl(', LibString.toString(hue), ',82%,62%)" stroke-width="1.5"/>'
            )
        );
    }

    /// @dev Crosshair at refraction point + optional annotations toggled by `accent` bits.
    function _refractionAnnotations(uint8 accent) private pure returns (string memory) {
        bytes memory s = abi.encodePacked(
            // crosshair at the refraction point (245, 250)
            '<g stroke="#fff" stroke-width="0.7" opacity="0.85">',
            '<line x1="245" y1="243" x2="245" y2="257"/>',
            '<line x1="238" y1="250" x2="252" y2="250"/>',
            '</g>'
        );
        // bit 0: angle arc
        if (accent & 0x01 != 0) {
            s = abi.encodePacked(
                s,
                '<path d="M 265,250 A 18,18 0 0,0 258,234" fill="none" stroke="#fff" stroke-width="0.5" stroke-dasharray="1,2" opacity="0.6"/>'
            );
        }
        // bit 1: entry-point crosshair on the prism face
        if (accent & 0x02 != 0) {
            s = abi.encodePacked(
                s,
                '<g stroke="#fff" stroke-width="0.5" opacity="0.6">',
                '<line x1="155" y1="244" x2="155" y2="256"/>',
                '<line x1="149" y1="250" x2="161" y2="250"/>',
                '</g>'
            );
        }
        // bit 2: secondary diagnostic dot near the exit
        if (accent & 0x04 != 0) {
            s = abi.encodePacked(s, '<circle cx="320" cy="180" r="2" fill="none" stroke="#fff" stroke-width="0.5" opacity="0.7"/>');
        }
        return string(s);
    }

    /// @dev Monospaced title block at the bottom: brand // seed digest, n, λ.
    function _titleBlock(bytes32 seed, uint16 nMilli, uint16 wavelength) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<g font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="9" fill="#fff" opacity="0.55">',
                '<text x="20" y="375">PRISM // ',  _digest(seed), '</text>',
                '<text x="380" y="375" text-anchor="end">n=', _formatMilli(nMilli),
                '   &#955;=', LibString.toString(wavelength), 'nm</text>',
                '</g>'
            )
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          FORMAT                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev "0xAABBCC" hex digest from the first 3 seed bytes.
    function _digest(bytes32 seed) private pure returns (string memory) {
        bytes memory hexChars = "0123456789ABCDEF";
        bytes memory out = new bytes(8);
        out[0] = "0"; out[1] = "x";
        for (uint256 i = 0; i < 3; i++) {
            uint8 b = uint8(seed[i]);
            out[2 + i * 2]     = hexChars[b >> 4];
            out[2 + i * 2 + 1] = hexChars[b & 0x0f];
        }
        return string(out);
    }

    /// @dev Format milli-fixed (e.g. 1523 → "1.523", 1050 → "1.050").
    function _formatMilli(uint16 milli) private pure returns (string memory) {
        uint16 whole = milli / 1000;
        uint16 frac  = milli % 1000;
        bytes memory fStr;
        if      (frac < 10)  fStr = abi.encodePacked("00", LibString.toString(frac));
        else if (frac < 100) fStr = abi.encodePacked("0",  LibString.toString(frac));
        else                 fStr = bytes(LibString.toString(frac));
        return string(abi.encodePacked(LibString.toString(whole), ".", fStr));
    }

    function _renderTraits(bytes32 seed) private pure returns (string memory) {
        uint16 hue        = uint16(uint256(uint8(seed[0])) * 360 / 256);
        uint16 nMilli     = 1450 + uint16(uint8(seed[1])) * 200 / 255;
        uint16 wavelength = 410 + uint16(uint8(seed[3])) % 290;
        return string(
            abi.encodePacked(
                '[',
                '{"trait_type":"Hue","value":',          LibString.toString(hue),        '},',
                '{"trait_type":"Refractive Index","value":"', _formatMilli(nMilli),       '"},',
                '{"trait_type":"Wavelength","value":"',  LibString.toString(wavelength), 'nm"}',
                ']'
            )
        );
    }
}
