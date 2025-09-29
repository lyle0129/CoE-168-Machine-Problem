`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.12.2024 12:27:41
// Design Name: 
// Module Name: lcd_controller
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module lcd_controller(
    input wire clk,           // 100 MHz clock
    input wire nrst,         // Active-low reset
    input wire [3:0] buttons, // BTN0-BTN3 inputs
    input wire sw0,           // SW0 input
    output reg [3:0] data,    // Data lines DB4-DB7
    output reg enable,        // Enable signal
    output reg rs            // Register Select
);

    // Parameters for LCD instructions
    parameter CMD_CLEAR_DISPLAY = 8'h01; // clear display
    parameter CMD_RETURN_HOME   = 8'h02; // return home
    parameter CMD_DISPLAY_ON_W_CURSOR_BLINK = 8'h0F; // Display on, cursor blinking
    parameter CMD_FUNCTION_SET  = 8'h28; // 4 bit mode, 2-line
    parameter CMD_DISPLAY_SHIFT_RIGHT = 8'h18; // display shifts right
    parameter CMD_DISPLAY_SHIFT_LEFT = 8'h1C; // display shifts left
    parameter CMD_MOVE_CURSOR_2ND_LINE = 8'hC0; // moves the cursor to the 2nd line
    parameter CMD_MOVE_CURSOR_LEFT = 8'h10; // moves the cursor left
    parameter CMD_MOVE_CURSOR_RIGHT = 8'h14; // moves the cursor left
    
    // state encoding
    parameter s_init = 2'b00;
    parameter s_wait = 2'b01;
    parameter s_typemode1 = 2'b10;
    parameter s_typemode2 = 2'b11;
    
    // global registers
    // Declare stored_vals as a memory array for 80 addresses
    reg [7:0] stored_vals [103:0]; // not yet used but i want to make use of it for typemode, 40 lines for line 1 and 40 lines for line 2, thats why its 80, also 8 bits to store the character in each tile 
    // Note: my implementation of above might be wrong
    reg [6:0] cursor_pos;    // 7-bit cursor position (0 to 79)
    reg [7:0] current_char;  // ASCII value of the current character
    
    reg [7:0] current_addr;
    reg [31:0] counter;
    reg [4:0] cmd_idx;
    reg [3:0] in_cmd_idx;//made into 4 bits for typemode purposes
    reg [1:0] state;
    reg [31:0] SOME_DELAY;
    reg [1:0] fake_en; //used for flagging if will trigger enable or not
    reg cmd_latch = 0;
    reg started = 0;
    reg [8:0] display_window_max;
    reg [5:0] repeater;
    
    // Maximum execution times in clock cycles (100 MHz clock)
    // will base the delays on the executions of the arduino library
    parameter T_CLEAR_DISPLAY = 32'd200000; // 2000 ms
    parameter T_RETURN_HOME   = 32'd200000; // 2000 ms
    parameter T_ENTRY_MODE    = 32'd4000;  // 40 µs
    parameter T_DISPLAY_ON    = 32'd4000;  // 40 µs
    parameter T_FUNCTION_SET  = 32'd4000;  // 40 µs
    parameter T_START         = 32'd2500000; // 25 ms
    parameter T_NIBBLE        = 32'd100; // 1 µs 
    parameter T_WAIT          = 32'd200000000; // 2 seconds
    parameter T_ENABLE        = 32'd45; // 450 ns

    // Debounce counters for each button
    reg [2:0] btn_pressed_reg;
    reg [19:0] debounce_counter [3:0]; // Separate counters for BTN3, BTN2, BTN1, BTN0
    reg [3:0] btn_stable;              // Stable signals after debouncing
    
    // Debounce logic
    integer i;
    always @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            debounce_counter[3] <= 0;
            debounce_counter[2] <= 0;
            debounce_counter[1] <= 0;
            debounce_counter[0] <= 0;
            btn_stable <= 4'b0000;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                if (buttons[i] == 1) begin
                    if (debounce_counter[i] < 20'd100000) begin
                        debounce_counter[i] <= debounce_counter[i] + 1; // Increment debounce counter
                    end else begin
                        btn_stable[i] <= 1; // Button press is stable
                    end
                end else begin
                    debounce_counter[i] <= 0; // Reset debounce counter
                    btn_stable[i] <= 0;       // Button is not pressed
                end
            end
        end
    end
    
    
    // this code is working but not debounced
    /*always @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            btn_stable <= 4'b0000;      // Reset stable button signals
        end else begin
            if (cmd_latch == 0) begin   // Only check buttons when cmd_latch is 0
                btn_stable <= buttons;  // Directly register current button states
            end else begin
                btn_stable <= 4'b0000;  // Ignore buttons while cmd_latch is active
            end
        end
    end*/
    
    
    // Button press detection
    reg [2:0] btn_pressed; // Encodes which button is pressed
    
    always @(*) begin
        if (cmd_latch == 0) begin //might change this if this didnt work
            if (btn_stable[3]) btn_pressed = 2'b11; // BTN3
            else if (btn_stable[2]) btn_pressed = 2'b10; // BTN2
            else if (btn_stable[1]) btn_pressed = 2'b01; // BTN1
            else if (btn_stable[0]) btn_pressed = 2'b00; // BTN0
            else btn_pressed = 3'b100; // No button pressed
        end
    end 
    
    //do not use this
    /*always @(*) begin
        if (cmd_latch == 0) begin
            if (btn_stable[3]) btn_pressed = BTN3;
            else if (btn_stable[2]) btn_pressed = BTN2;
            else if (btn_stable[1]) btn_pressed = BTN1;
            else if (btn_stable[0]) btn_pressed = BTN0;
            else btn_pressed = NONE;
        end else begin
            btn_pressed = NONE;  // Ignore button input when cmd_latch is active
        end
    end*/
    
    // Define button parameters for clarity
    parameter BTN3 = 2'b11; // Corresponds to buttons[3]
    parameter BTN2 = 2'b10; // Corresponds to buttons[2]
    parameter BTN1 = 2'b01; // Corresponds to buttons[1]
    parameter BTN0 = 2'b00; // Corresponds to buttons[0]
    parameter NONE = 3'b100; // Corresponds to nothing pressed
    
    
    //Turning this off muna to account for button debouncing 2.0
    /*// Register logic for storing the button press
    always @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            btn_pressed_reg = 3'b100; // Reset button press
        end else if (cmd_latch == 0) begin
            btn_pressed_reg = btn_pressed; // Update with current btn_pressed value
        end
    end*/
    
    reg [3:0] btn_stable_prev;   // Previous state of debounced buttons
    reg btn_latched;             // Latch to hold if a button press is detected
    
    // Button Debouncing 2.0
    // Edge detection for button presses
    always @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            btn_stable_prev <= 4'b0000;    // Reset previous state
            btn_pressed_reg <= NONE;       // Reset button press register
            btn_latched <= 0;              // Clear latch
        end else begin
            // Update previous state of btn_stable
            btn_stable_prev <= btn_stable;
    
            // Rising edge detection and latch logic
            if (cmd_latch == 0 && !btn_latched) begin
                case (btn_stable & ~btn_stable_prev)  // Detect rising edge
                    4'b1000: begin
                        btn_pressed_reg <= BTN3; // BTN3 pressed
                        btn_latched <= 1;        // Set latch
                    end
                    4'b0100: begin
                        btn_pressed_reg <= BTN2; // BTN2 pressed
                        btn_latched <= 1;        // Set latch
                    end
                    4'b0010: begin
                        btn_pressed_reg <= BTN1; // BTN1 pressed
                        btn_latched <= 1;        // Set latch
                    end
                    4'b0001: begin
                        btn_pressed_reg <= BTN0; // BTN0 pressed
                        btn_latched <= 1;        // Set latch
                    end
                    default: begin
                        btn_pressed_reg <= NONE; // No new press
                        btn_latched <= 0;        // Clear latch
                    end
                endcase
            end
    
            // Reset latch when cmd_latch is active (button processing starts)
            if (cmd_latch == 1) begin
                btn_latched <= 0;  // Clear latch to allow next detection
            end
        end
    end
    
    // -------------- Main File ----------------------- //
    always @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            // Reset sequence 
            // Note Have to make this the reset sequence of the actual LCD
            counter = 0;
            cmd_idx = 0;
            state = s_init;
            enable = 0;
            rs = 0;
            data = 0;
            SOME_DELAY = T_START;
            in_cmd_idx = 0;
            fake_en = 1;
            current_char = 8'h20;
            cursor_pos = 0;
            cmd_latch = 0;
            display_window_max = 9'd15;
            repeater = 6'd0;
            // Initialize stored_vals to 8'h20
            for (i = 0; i < 103; i = i + 1) begin
                stored_vals[i] = 8'h20;
            end
            
            if (started == 1)begin // new addition as latch of startup
                cmd_idx = 2;
            end
        end else begin
            case (state)
                s_init: begin
                    if (counter == SOME_DELAY) begin
                        started = 1;
                        counter = 0;
                        // Send commands based on cmd_idx
                        case (cmd_idx)
                            0: begin // send 0010 (4'h2)
                                data = CMD_FUNCTION_SET[7:4];
                                SOME_DELAY = T_FUNCTION_SET;
                                cmd_idx = cmd_idx + 1;
                            end
                            1: begin // send 0010 1000 (4 bit mode, 2 line)
                                if (in_cmd_idx == 0) begin
                                    data = CMD_FUNCTION_SET[7:4];
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = CMD_FUNCTION_SET[3:0];
                                    SOME_DELAY = T_FUNCTION_SET;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            2: begin // send clear display (0000 0001)
                                if (in_cmd_idx == 0) begin
                                    data = CMD_CLEAR_DISPLAY[7:4];
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = CMD_CLEAR_DISPLAY[3:0];
                                    SOME_DELAY = T_CLEAR_DISPLAY;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            3: begin // return home (0000 0010)
                                if (in_cmd_idx == 0) begin
                                    data = CMD_RETURN_HOME[7:4];
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = CMD_RETURN_HOME[3:0];
                                    SOME_DELAY = T_RETURN_HOME;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            4: begin // display settings (0000 1111)
                                if (in_cmd_idx == 0) begin
                                    data = CMD_DISPLAY_ON_W_CURSOR_BLINK[7:4];
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else if (in_cmd_idx == 1) begin
                                    data = CMD_DISPLAY_ON_W_CURSOR_BLINK[3:0];
                                    SOME_DELAY = T_DISPLAY_ON;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin //turn RS early
                                    rs = 1;
                                    fake_en = 0; // NOTE set flag to 0 do that wont turn enable
                                    SOME_DELAY = 27'd140;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            5: begin //write L
                                fake_en = 1; // return the flag to 1 so that enable would function
                                rs = 1; 
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'hc;
                                    SOME_DELAY = T_DISPLAY_ON;//same delay as with sending naman
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            6: begin //Y
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h5;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'h9;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            7: begin //L
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'hc;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            8: begin //E
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else if (in_cmd_idx == 1) begin
                                    data = 4'h5;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin //turning RS off early
                                    rs = 0;
                                    fake_en = 0; // fake enable so that no trigger again
                                    cmd_idx = cmd_idx + 1;
                                    SOME_DELAY = 27'd140;
                                    in_cmd_idx = 0;
                                end
                            end
                            9: begin //MOVE CURSOR
                                fake_en = 1;
                                rs = 0;
                                if (in_cmd_idx == 0) begin
                                    data = CMD_MOVE_CURSOR_2ND_LINE[7:4];
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else if (in_cmd_idx == 1) begin
                                    data = CMD_MOVE_CURSOR_2ND_LINE[3:0];
                                    SOME_DELAY = T_DISPLAY_ON; // no delay of specific but same naman
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin // turn rs on early again
                                    rs = 1;
                                    fake_en = 0; // fake en again so not to trigger enable
                                    cmd_idx = cmd_idx + 1;
                                    SOME_DELAY = 27'd140;
                                    in_cmd_idx = 0;
                                end
                            end
                            10: begin //T
                                fake_en = 1; // turn enable on again
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h5;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'h4;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            11: begin //R
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h5;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'h2;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            12: begin //I
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'h9;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            13: begin //L
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'hC;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            14: begin //L
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'hC;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            15: begin //A
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'h1;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            16: begin //N
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'hE;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            17: begin //E
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h4;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'h5;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            18: begin //S
                                rs = 1;
                                if (in_cmd_idx == 0) begin
                                    data = 4'h5;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else if (in_cmd_idx == 1) begin
                                    data = 4'h3;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    rs = 0;
                                    fake_en = 0;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                    SOME_DELAY = 27'd140;
                                end
                            end
                            19: begin //MOVE CURSOR UNSEEABLE
                                fake_en = 1;
                                rs = 0;
                                if (in_cmd_idx == 0) begin
                                    data = 4'hE;
                                    SOME_DELAY = T_NIBBLE;
                                    in_cmd_idx = in_cmd_idx + 1;
                                end else begin
                                    data = 4'H7;
                                    SOME_DELAY = T_DISPLAY_ON;
                                    cmd_idx = cmd_idx + 1;
                                    in_cmd_idx = 0;
                                end
                            end
                            20: begin
                                rs = 0;
                                state = s_wait;
                                SOME_DELAY = T_WAIT;
                                fake_en = 0; // fake enable so that no trigger again
                            end
                            
                            default: begin 
                                state = s_wait; // Proceed to wait state
                                SOME_DELAY = T_WAIT;
                            end
                        endcase
                        if (fake_en == 1)begin
                            enable = 1; // Generate enable pulse
                        end
                    end if (enable == 1 && counter == T_ENABLE) begin
                        enable = 0; // makes sure that enable is on for 450 ns
                    end else begin
                        counter = counter + 1;
                    end
                end
                
                // ------------ wait for 2 seconds then clear ---- //
                s_wait: begin
                    
                    if (counter == SOME_DELAY) begin
                        rs = 0;
                        counter = 0;
                        if (in_cmd_idx == 0) begin
                            fake_en = 1;
                            data = CMD_CLEAR_DISPLAY[7:4];
                            SOME_DELAY = T_NIBBLE;
                            in_cmd_idx = in_cmd_idx + 1;
                        end else if (in_cmd_idx == 1) begin
                            data = CMD_CLEAR_DISPLAY[3:0];
                            SOME_DELAY = T_CLEAR_DISPLAY;
                            in_cmd_idx = in_cmd_idx + 1;
                        end else begin
                            state = s_typemode1;
                            in_cmd_idx = 0;
                            rs = 1; 
                            fake_en = 0;
                        end
                        if (fake_en == 1)begin
                            enable = 1; // Generate enable pulse
                        end
                    end if (enable == 1 && counter == T_ENABLE) begin
                        enable = 0; // makes sure that enable is on for 450 ns
                    end else begin
                        counter = counter + 1; // Increment counter
                    end
                end
                
                // To follow for the code of this ---------------------------------
                s_typemode1: begin // swith is down (browsing of printable characters)
                    if (sw0) begin
                        
                        if (enable == 1 && counter == T_ENABLE) begin
                            enable = 0; // Ensure enable is deasserted after pulse
                        
                        end if (counter == SOME_DELAY) begin
                        //insert redo here
                            counter = 0;
                            if (in_cmd_idx == 0) begin
                                rs = 1; // Data mode
                                fake_en = 1;
                                data = stored_vals[cursor_pos][7:4]; // Upper nibble
                                SOME_DELAY = T_NIBBLE;
                                in_cmd_idx = in_cmd_idx + 1;
                            end else if (in_cmd_idx == 1) begin
                                data = stored_vals[cursor_pos][3:0]; // Lower nibble
                                SOME_DELAY = T_DISPLAY_ON;
                                in_cmd_idx = in_cmd_idx + 1;
                                //btn_pressed_reg = 3'b100; 
                            end else if (in_cmd_idx == 2) begin
                                // Return to cursor position
                                rs = 0; // Command mode
                                SOME_DELAY = 27'd140;
                                in_cmd_idx = in_cmd_idx + 1;
                                fake_en = 0;
                            end else if (in_cmd_idx == 3) begin
                                fake_en = 1;
                                data = {1'b1, cursor_pos[6:4]}; // Move to top line position
                                SOME_DELAY = T_NIBBLE;
                                in_cmd_idx = in_cmd_idx + 1;
                            end else if (in_cmd_idx == 4) begin
                                data = cursor_pos[3:0]; // Move to top line position
                                SOME_DELAY = T_DISPLAY_ON;
                                in_cmd_idx = in_cmd_idx + 1;
                            end else begin
                                in_cmd_idx = 0;
                                fake_en = 0;
                                state = s_typemode2; // Switch to typemode2 if SW0 is UP
                            end 
                        
                        if (fake_en == 1)begin
                            enable = 1; // Generate enable pulse
                        end
                        end else begin
                            counter = counter + 1; // Increment counter
                        end      
                    end else begin
                        // counter for enable pulse
                        if (enable == 1 && counter == T_ENABLE) begin
                            enable = 0; // Ensure enable is deasserted after pulse
                        
                        end if (counter == SOME_DELAY) begin
                        // write logic code here //
                            counter = 0; // Reset counter
                            case (btn_pressed_reg)
                                BTN2: begin // Browse characters forward
                                    
                                    if (cmd_latch == 0) begin
                                        cmd_latch = 1;
                                        current_char = (current_char == 8'h7E) ? 8'h20 : current_char + 1;
                                        //btn_pressed_reg = BTN2;
                                    end
                                    
                                    if (in_cmd_idx == 0) begin
                                        rs = 1; // Data mode
                                        fake_en = 1;
                                        data = current_char[7:4]; // Upper nibble
                                        SOME_DELAY = T_NIBBLE;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 1) begin
                                        data = current_char[3:0]; // Lower nibble
                                        SOME_DELAY = T_DISPLAY_ON;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 2) begin
                                        // Return to cursor position
                                        rs = 0; // Command mode
                                        SOME_DELAY = 27'd140;
                                        in_cmd_idx = in_cmd_idx + 1;
                                        fake_en = 0;
                                    end else if (in_cmd_idx == 3) begin
                                        fake_en = 1;
                                        data = {1'b1, cursor_pos[6:4]}; // Move to top line position
                                        SOME_DELAY = T_NIBBLE;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 4) begin
                                        data = cursor_pos[3:0]; // Move to top line position
                                        SOME_DELAY = T_DISPLAY_ON;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 5) begin
                                        rs = 1;
                                        SOME_DELAY = 27'd140;
                                        in_cmd_idx = 0;
                                        cmd_latch = 0;
                                        fake_en = 0;
                                        //btn_pressed_reg = 3'b100;   
                                    end
                                end
                
                                BTN3: begin // Browse characters backward
                                    
                                    if (cmd_latch == 0) begin
                                        cmd_latch = 1;
                                        current_char = (current_char == 8'h20) ? 8'h7E : current_char - 1;
                                        //btn_pressed_reg = BTN3;
                                    end
                                    
                                    if (in_cmd_idx == 0) begin
                                        rs = 1; // Data mode
                                        fake_en = 1;
                                        data = current_char[7:4]; // Upper nibble
                                        SOME_DELAY = T_NIBBLE;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 1) begin
                                        data = current_char[3:0]; // Lower nibble
                                        SOME_DELAY = T_DISPLAY_ON;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 2) begin
                                        // Return to cursor position
                                        rs = 0; // Command mode
                                        SOME_DELAY = 27'd140;
                                        fake_en = 0;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 3) begin
                                        fake_en = 1;
                                        data = {1'b1, cursor_pos[6:4]}; // Move to top line position
                                        SOME_DELAY = T_NIBBLE;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 4) begin
                                        data = cursor_pos[3:0]; // Move to top line position
                                        SOME_DELAY = T_DISPLAY_ON;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 5) begin
                                        rs = 1;
                                        fake_en = 0;
                                        SOME_DELAY = 27'd140;
                                        in_cmd_idx = 0;
                                        cmd_latch = 0;
                                        //btn_pressed_reg = 3'b100;   
                                    end
                                end
                
                                BTN0: begin // Write character to memory and move cursor
                                    
                                    if (cmd_latch == 0) begin
                                        cmd_latch = 1;
                                        //btn_pressed_reg = BTN0;
                                        stored_vals[cursor_pos] = current_char; // Save to internal memory
                                        if (cursor_pos == 39) cursor_pos = cursor_pos + 25; // Move to bottom line
                                        else cursor_pos = cursor_pos + 1; // advance position by 1
                                        //write if (cursor_pos == 103) cursor_pos = 0;
                                    end
                                    
                                    //write logic of shifting here
                                    // insert code for display window here
                                    if (cursor_pos == 64) begin
                                        //do action to move display
                                        if (in_cmd_idx == 0) begin
                                            rs = 0; // Command mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1;
                                        end else if (in_cmd_idx == 1) begin
                                            fake_en = 1;
                                            data = 4'h1; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 2) begin
                                            data = 4'h8; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            repeater = repeater + 1;
                                            if (repeater < 16) begin
                                                in_cmd_idx = in_cmd_idx - 1;
                                            end else begin
                                                in_cmd_idx = in_cmd_idx + 1;
                                                repeater = 0;
                                            end
                                        end else if (in_cmd_idx == 3) begin
                                            rs = 1; // Type mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1 + in_cmd_idx;
                                        end else if (in_cmd_idx == 4) begin
                                            rs = 1; // Data mode
                                            fake_en = 1;
                                            data = current_char[7:4]; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 5) begin
                                            data = current_char[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = 0;
                                            cmd_latch = 0;
                                            current_char = stored_vals[cursor_pos];
                                            display_window_max = 64 + 15;
                                            //btn_pressed_reg = 3'b100; 
                                        end  
                                    end else if (cursor_pos > display_window_max) begin
                                        //do action to move display
                                        if (in_cmd_idx == 0) begin
                                            rs = 0; // Command mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1;
                                        end else if (in_cmd_idx == 1) begin
                                            fake_en = 1;
                                            data = 4'h1; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 2) begin
                                            data = 4'h8; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = in_cmd_idx + 1;
                                            //btn_pressed_reg = 3'b100;
                                        end else if (in_cmd_idx == 3) begin
                                            rs = 1; // Type mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1 + in_cmd_idx;
                                        end else if (in_cmd_idx == 4) begin
                                            rs = 1; // Data mode
                                            fake_en = 1;
                                            data = current_char[7:4]; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 5) begin
                                            data = current_char[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = 0;
                                            cmd_latch = 0;
                                            current_char = stored_vals[cursor_pos];
                                            display_window_max = display_window_max + 1;
                                            //btn_pressed_reg = 3'b100; 
                                        end
                                    end else begin
                                        // original code to be found inside else block
                                        if (in_cmd_idx == 0) begin
                                            rs = 1; // Data mode
                                            fake_en = 1;
                                            data = current_char[7:4]; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 1) begin
                                            data = current_char[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = 0;
                                            cmd_latch = 0;
                                            current_char = stored_vals[cursor_pos];
                                            //btn_pressed_reg = 3'b100; 
                                        end
                                    end
                                    
                                end
                
                                BTN1: begin // Erase character
                                    
                                    if (cursor_pos > 0 && cmd_latch == 0) begin
                                        cmd_latch = 1;
                                        cursor_pos = cursor_pos - 1;
                                        stored_vals[cursor_pos] = current_char;
                                        //btn_pressed_reg = BTN1;
                                    end   
                                    if (in_cmd_idx == 0) begin
                                        
                                        fake_en = 0;
                                        rs = 0;
                                        SOME_DELAY = 27'd140;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 1) begin
                                        fake_en = 1;
                                        data = {1'b1, cursor_pos[6:4]}; // Upper nibble (space)
                                        SOME_DELAY = T_NIBBLE;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 2) begin
                                        data = cursor_pos[3:0]; // Upper nibble (space)
                                        SOME_DELAY = T_DISPLAY_ON;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 3) begin
                                        rs = 1;
                                        fake_en = 0;
                                        SOME_DELAY = 27'd140;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 4) begin
                                        fake_en = 1;
                                        data = 4'h2; // Upper nibble (space)
                                        SOME_DELAY = T_NIBBLE;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else if (in_cmd_idx == 5) begin
                                        data = 4'h0; // Upper nibble (space)
                                        SOME_DELAY = T_DISPLAY_ON;
                                        in_cmd_idx = 0;
                                        cmd_latch = 0;
                                        //btn_pressed_reg = 3'b100;   
                                    end
                                end
                                default: begin
                                    //btn_pressed_reg = 3'b100;
                                    fake_en = 0;
                                    cmd_latch = 0;
                                end
                            endcase 
                            if (fake_en == 1)begin
                                enable = 1; // Generate enable pulse
                            end
                        // note I want my buttons to have some form of debounce
                        end else begin
                            counter = counter + 1; // Increment counter
                        end 
                    end
                end 

            
                s_typemode2: begin // switch is UP (cursor control)
                    if (!sw0) begin
                        state = s_typemode1; // Switch to typemode1 if SW0 is DOWN
                        current_char = stored_vals[cursor_pos];
                    end else begin
                        // counter for enable pulse
                        if (enable == 1 && counter == T_ENABLE) begin
                            enable = 0; // Ensure enable is deasserted after pulse
                        
                        end if (counter == SOME_DELAY) begin
                        // write logic code here //
                            counter = 0; // Reset counter
                            case (btn_pressed_reg)
                                BTN3: begin // Move cursor left
                                    
                                    if (cmd_latch == 0) begin
                                        cmd_latch = 1;
                                        //btn_pressed_reg = BTN3;
                                        if (cursor_pos > 63)begin
                                            cursor_pos = (cursor_pos == 64) ? 39 : cursor_pos - 1; // Wrap cursor
                                        end else begin
                                            cursor_pos = (cursor_pos == 0) ? 103 : cursor_pos - 1; // Wrap cursor
                                        end
                                    end
                                    // insert code for display window here
                                    if (cursor_pos == 39 || cursor_pos == 103) begin
                                        //do action to move display
                                        if (in_cmd_idx == 0) begin
                                            rs = 0; // Command mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1;
                                            
                                        end else if (in_cmd_idx == 1) begin
                                            fake_en = 1;
                                            data = {1'b1,cursor_pos[6:4]}; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 2) begin
                                            data = cursor_pos[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = in_cmd_idx +1;
                                            //btn_pressed_reg = 3'b100;
                                        end else if (in_cmd_idx == 3) begin
                                            fake_en = 1;
                                            data = 4'h1; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 4) begin
                                            data = 4'hc; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            repeater = repeater + 1;
                                            if (repeater < 16) begin
                                                in_cmd_idx = in_cmd_idx - 1;
                                            end else begin
                                                in_cmd_idx = 0;
                                                cmd_latch = 0;
                                                repeater = 0;
                                                if (cursor_pos == 39) display_window_max = 39;
                                                if (cursor_pos == 103) display_window_max = 103;
                                            end
                                            //btn_pressed_reg = 3'b100;
                                        end
                                    end else if (cursor_pos < (display_window_max - 15)) begin
                                        //do action to move display
                                        if (in_cmd_idx == 0) begin
                                            rs = 0; // Command mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1;
                                            
                                        end else if (in_cmd_idx == 1) begin
                                            fake_en = 1;
                                            data = {1'b1,cursor_pos[6:4]}; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 2) begin
                                            data = cursor_pos[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = in_cmd_idx +1;
                                            //btn_pressed_reg = 3'b100;
                                        end else if (in_cmd_idx == 3) begin
                                            fake_en = 1;
                                            data = 4'h1; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 4) begin
                                            data = 4'hc; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = 0;
                                            display_window_max = display_window_max - 1;
                                            cmd_latch = 0;
                                            //btn_pressed_reg = 3'b100;
                                        end    
                                    end else begin
                                        if (in_cmd_idx == 0) begin
                                            rs = 0; // Command mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1;
                                        end else if (in_cmd_idx == 1) begin
                                            fake_en = 1;
                                            data = {1'b1,cursor_pos[6:4]}; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 2) begin
                                            data = cursor_pos[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = 0;
                                            cmd_latch = 0;
                                            //btn_pressed_reg = 3'b100;
                                        end
                                    end
                                end
                                BTN2: begin // Move cursor right
                                    
                                    if (cmd_latch == 0) begin
                                        cmd_latch = 1;
                                        //btn_pressed_reg = BTN2;
                                        if (cursor_pos < 40) begin
                                            cursor_pos = (cursor_pos == 39) ? 64 : cursor_pos + 1; // Wrap cursor
                                        end else begin
                                            cursor_pos = (cursor_pos == 103) ? 0 : cursor_pos + 1; // Wrap cursor
                                        end
                                    end
                                    // insert code for display window here
                                    if (cursor_pos == 64 || cursor_pos == 0) begin
                                        //do action to move display
                                        if (in_cmd_idx == 0) begin
                                            rs = 0; // Command mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1;
                                            
                                        end else if (in_cmd_idx == 1) begin
                                            fake_en = 1;
                                            data = {1'b1,cursor_pos[6:4]}; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 2) begin
                                            data = cursor_pos[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = in_cmd_idx +1;
                                            //btn_pressed_reg = 3'b100;
                                        end else if (in_cmd_idx == 3) begin
                                            fake_en = 1;
                                            data = 4'h1; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 4) begin
                                            data = 4'h8; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            repeater = repeater + 1;
                                            if (repeater < 16) begin
                                                in_cmd_idx = in_cmd_idx - 1;
                                            end else begin
                                                in_cmd_idx = 0;
                                                cmd_latch = 0;
                                                repeater = 0;
                                                if (cursor_pos == 64) display_window_max = 64 + 15;
                                                if (cursor_pos == 0) display_window_max = 0 + 15;
                                            end
                                            //btn_pressed_reg = 3'b100;
                                        end     
                                    end else if (cursor_pos > display_window_max) begin
                                        //do action to move display
                                        if (in_cmd_idx == 0) begin
                                            rs = 0; // Command mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1;
                                            
                                        end else if (in_cmd_idx == 1) begin
                                            fake_en = 1;
                                            data = {1'b1,cursor_pos[6:4]}; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 2) begin
                                            data = cursor_pos[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = in_cmd_idx +1;
                                            //btn_pressed_reg = 3'b100;
                                        end else if (in_cmd_idx == 3) begin
                                            fake_en = 1;
                                            data = 4'h1; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 4) begin
                                            data = 4'h8; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            display_window_max = display_window_max + 1;
                                            in_cmd_idx = 0;
                                            cmd_latch = 0;
                                            //btn_pressed_reg = 3'b100;
                                        end    
                                    end else begin
                                        if (in_cmd_idx == 0) begin
                                            rs = 0; // Command mode
                                            fake_en = 0;
                                            SOME_DELAY = 27'd140;
                                            rs = 0;
                                            in_cmd_idx = 1;
                                        end else if (in_cmd_idx == 1) begin
                                            fake_en = 1;
                                            data = {1'b1,cursor_pos[6:4]}; // Upper nibble
                                            SOME_DELAY = T_NIBBLE;
                                            in_cmd_idx = in_cmd_idx + 1;
                                        end else if (in_cmd_idx == 2) begin
                                            data = cursor_pos[3:0]; // Lower nibble
                                            SOME_DELAY = T_DISPLAY_ON;
                                            in_cmd_idx = 0;
                                            cmd_latch = 0;
                                            //btn_pressed_reg = 3'b100;
                                        end
                                    end
                                end
                                BTN0: begin // Switch between lines
                                    
                                    if (cmd_latch == 0) begin
                                        cmd_latch = 1;
                                        //btn_pressed_reg = BTN0;
                                        if (cursor_pos < 40) begin 
                                            cursor_pos = cursor_pos + 64; // Move to bottom line
                                            display_window_max = display_window_max + 64;
                                        end else begin
                                            cursor_pos = cursor_pos - 64; // Move to top line
                                            display_window_max = display_window_max - 64;
                                        end
                                    end
                                    
                                    if (in_cmd_idx == 0) begin
                                        rs = 0; // Command mode
                                        fake_en = 0;
                                        SOME_DELAY = 27'd140;
                                        rs = 0;
                                        in_cmd_idx = 1;
                                    end else if (in_cmd_idx == 1) begin
                                        fake_en = 1;
                                        data = {1'b1,cursor_pos[6:4]}; // Upper nibble
                                        SOME_DELAY = T_NIBBLE;
                                        in_cmd_idx = in_cmd_idx + 1;
                                    end else begin
                                        data = cursor_pos[3:0]; // Lower nibble
                                        SOME_DELAY = T_DISPLAY_ON;
                                        in_cmd_idx = 0;
                                        //btn_pressed_reg = 3'b100;
                                        cmd_latch = 0;
                                    end
                                end
                                default: begin
                                    //btn_pressed_reg = 3'b100;
                                    fake_en = 0;
                                    cmd_latch = 0;
                                end
                            endcase 
                            if (fake_en == 1)begin
                                enable = 1; // Generate enable pulse
                            end
                        // note I want my buttons to have some form of debouncer
                        end else begin
                            counter = counter + 1; // Increment counter
                        end
                    end
                end 
                default: state <= s_wait; // Fallback
            endcase
        end
    end
endmodule
