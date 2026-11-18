package rangefinder_pkg;

    // Distance width in millimeters
    parameter int unsigned DIST_WIDTH = 12;

    // Valid distance range in millimeters
    parameter int unsigned DEFAULT_DIST_MIN_MM = 20;
    parameter int unsigned DEFAULT_DIST_MAX_MM = 4000;


    // Returns the maximum of two integers
    function automatic integer imax(
        input integer a,
        input integer b
    );
        if (a > b) begin
            return a;
        end else begin
            return b;
        end
    endfunction

    // Returns the number of bits required to represent a non-negative integer value
    function automatic integer bit_width(
        input integer val
    );
        if (val <= 1) begin
            return 1;
        end else begin
            return $clog2(val + 1);
        end
    endfunction

endpackage