/// Completes initialisation for Chatterbox
/// This script should be called after chatterbox_init_start() and chatterbox_init_add()
/// 
/// This script goes through a number of steps to parse Yarn source files to prepare them for internal use.
/// 1) Load the source file into a buffer, and break it down into individual nodes
/// 2) Perform bulk findreplace tasks (via init_permit_script())
/// 2) Get the text body of the node, and break it down into individual lines and substrings
///
/// Once we have the body broken down into substrings, we can start to store "instructions".
/// Instructions represent the logic that Chatterbox will execute to work out what text needs to be displayed.
/// Instructions are all stored in a single enormous global list - this helps with redirects and options.
///
/// 3) For each substring, detect whether it's a) text or a shortcut b) a redirect or option c) an action
/// 3a) If a substring is text or shortcut, store it as a simple instruction
/// 3b) If a substring is a redirect or option, work out where it's pointing and store that instruction
/// 3c) If a substring is an action: tokenise, build a syntax tree, add an instruction that holds the syntax tree
/// 4) Add a STOP instruction to the end of the node's instructions to catch any weird behaviour
///
/// "Actions" give Chatterbox an enormous amount of flexibility!
/// To find out more about Chatterbox's scripting language, "Yarn", please read the __chatterbox_syntax().
/// 
/// Once this script has been run, Chatterbox is ready for use!

var _timer = get_timer();

if ( !variable_global_exists("__chatterbox_init_complete" ) )
{
    show_error("Chatterbox:\nchatterbox_init_end() should be called after chatterbox_init_start()\n ", false);
    exit;
}

show_debug_message("Chatterbox: Chatterbox initialisation started");



var _font_count = ds_map_size(global.__chatterbox_file_data);
var _name = ds_map_find_first(global.__chatterbox_file_data);
repeat(_font_count)
{
    var _font_data = global.__chatterbox_file_data[? _name ];
    show_debug_message("Chatterbox:   Processing file \"" + _name + "\"");
    
    var _filename = _font_data[ __CHATTERBOX_FILE.FILENAME ];
    
    
    
    ds_list_add(global.__chatterbox_vm, _filename);
    var _instruction_file_offset = ds_list_size(global.__chatterbox_vm);
    global.__chatterbox_goto[? _filename ] = _instruction_file_offset;
    if (CHATTERBOX_DEBUG_PARSER) show_debug_message("Chatterbox:     File instruction offset is " + string(_instruction_file_offset));
    
    
    
    
    var _buffer = buffer_load(global.__chatterbox_font_directory + _filename);
    var _string = buffer_read(_buffer, buffer_string);
    buffer_delete(_buffer);
    
    var _yarn_json = json_decode(_string);
    
    //Test for JSON made by the standard Yarn editor
    var _node_list = _yarn_json[? "default" ];
    if (_node_list != undefined) show_debug_message("Chatterbox:     File was made in standard Yarn editor");
    
    //Test for JSON made by Jacquard
    if (_node_list == undefined)
    {
        var _node_list = _yarn_json[? "nodes" ];
        if (_node_list != undefined) show_debug_message("Chatterbox:     File was made by Jacquard");
    }
    
    //If both of these fail, it's some wacky JSON that we don't recognise
    if (_node_list == undefined)
    {
        show_error("Chatterbox:\nJSON format for \"" + _name + "\" is unrecognised.\nThis source file will be ignored.\n ", false);
        _name = ds_map_find_next(global.__chatterbox_file_data, _name);
        continue;
    }
    
    
    
    var _node_count = ds_list_size(_node_list);
    if (_node_count > 0)
    {
        show_debug_message("Chatterbox:     Found " + string(_node_count) + " titles:");
        var _string = "Chatterbox:       ";
        
        //Debug output that displays all the nodes in a file
        var _i = 0;
        for(var _node = 0; _node < _node_count; _node++)
        {
            var _node_map = _node_list[| _node];
            
            _string += "\"" + _node_map[? "title" ] + "\"";
            if (_node < _node_count-1)
            {
                _string += ", ";
                _i++;
                if (_i >= 10)
                {
                    show_debug_message(_string);
                    _string = "Chatterbox:       ";
                    _i = 0;
                }
            }
        }
        if (_i > 0) show_debug_message(_string);
    }
    
    
    
    for(var _node = 0; _node < _node_count; _node++)
    {
        var _node_map = _node_list[| _node];
        var _title = _node_map[? "title" ];
        var _body  = _node_map[? "body"  ];
        
        //Prepare body string for parsing
        _body = string_replace_all(_body, "\n\r", "\n");
        _body = string_replace_all(_body, "\r\n", "\n");
        _body = string_replace_all(_body, "\r"  , "\n");
        
        //Perform find-replace
        var _size = ds_list_size(global.__chatterbox_findreplace_old_string);
        for(var _i = 0; _i < _size; _i++)
        {
            _body = string_replace_all(_body,
                                       global.__chatterbox_findreplace_old_string[| _i ],
                                       global.__chatterbox_findreplace_new_string[| _i ]);
        }
        
        if (CHATTERBOX_DEBUG_PARSER)
        {
            show_debug_message("Chatterbox:     Processing \"" + string(_title) + "\" = \"" + string_replace_all(string(_body), "\n", "\\n") + "\"");
        }
        _body += "\n";
        
        ds_list_add(global.__chatterbox_vm, _filename + CHATTERBOX_FILENAME_SEPARATOR + _title);
        var _instruction_node_offset = ds_list_size(global.__chatterbox_vm);
        global.__chatterbox_goto[? _filename + CHATTERBOX_FILENAME_SEPARATOR + _title ] = _instruction_node_offset;
        if (CHATTERBOX_DEBUG_PARSER) show_debug_message("Chatterbox:       Node instruction offset is " + string(_instruction_node_offset));
        
        
        
        #region Parse the body text for this node
        
        var _body_read = 0;
        var _body_read_prev = 1;
        repeat(string_length(_body))
        {
            _body_read++;
            var _body_char = string_char_at(_body, _body_read);
            
            if (_body_char == "\n")
            {
                var _line_string = string_copy(_body, _body_read_prev, _body_read - _body_read_prev);
                _body_read_prev = _body_read+1;
                
                //Strip whitespace from the start of the string
                _line_string = __chatterbox_remove_whitespace(_line_string, true);
                var _indent = global.__chatterbox_indent_size;
                
                if (CHATTERBOX_ERROR_ON_BAD_INDENTS)
                {
                    if (_indent != CHATTERBOX_INDENT_UNIT_SIZE*floor(_indent/CHATTERBOX_INDENT_UNIT_SIZE))
                    {
                        show_error("Chatterbox:\nLine has an invalid amount of indentation (" + string(_indent) + "). It must be a multiple of " + string(CHATTERBOX_INDENT_UNIT_SIZE) + ".\n(Line was \"" + string(_line_string) + "\")", false);
                    }
                }
                
                if (_line_string == "") continue;
                
                //Strip whitespace from the end of the string
                _line_string = __chatterbox_remove_whitespace(_line_string, false);
                
                var _in_option = false;
                var _in_action = false;
                var _first_token = true;
                var _line_read = 0;
                var _line_char = "";
                var _line_read_prev = 1;
                var _line_char_prev = "";
                var _length = string_length(_line_string);
                repeat(_length)
                {
                    _line_read++;
                    var _string = "";
                    
                    _line_char_prev = _line_char;
                    var _line_char = string_char_at(_line_string, _line_read);
                    
                    if (_line_char_prev == _line_char)
                    && (  ( _in_option && (_line_char == CHATTERBOX_OPTION_CLOSE_DELIMITER))
                       || ( _in_action && (_line_char == CHATTERBOX_ACTION_CLOSE_DELIMITER))
                       || (!_in_option && (_line_char == CHATTERBOX_OPTION_OPEN_DELIMITER))
                       || (!_in_action && (_line_char == CHATTERBOX_ACTION_OPEN_DELIMITER))  )
                    {
                            _string = string_copy(_line_string, _line_read_prev, _line_read-1 - _line_read_prev);
                            _line_read_prev = _line_read+1;
                    }
                    else if (_line_read == _length)
                    {
                        _string = string_copy(_line_string, _line_read_prev, 1 + _line_read - _line_read_prev);
                    }
                    
                    if (_string != "")
                    {
                        _string = __chatterbox_remove_whitespace(__chatterbox_remove_whitespace(_string, true), false);
                        if (_string != "")
                        {
                            var _array = array_create(__CHATTERBOX_INSTRUCTION.__SIZE);
                            _array[ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_UNKNOWN;
                            _array[ __CHATTERBOX_INSTRUCTION.INDENT  ] = _indent;
                            _array[ __CHATTERBOX_INSTRUCTION.CONTENT ] = undefined;
                            
                            if (_in_option)
                            {
                                _in_option = false;
                        
                                #region [[option]]
                        
                                var _pos = string_pos("|", _string);
                                if (_pos < 1)
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_REDIRECT;
                                    _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = [_string];
                                }
                                else
                                {
                                    var _content = [ __chatterbox_remove_whitespace(string_copy(_string, 1, _pos-1), false),
                                                     __chatterbox_remove_whitespace(string_delete(_string, 1, _pos), true) ];
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_OPTION;
                                    _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = _content;
                                }
                        
                                #endregion
                            }
                            else if (_in_action)
                            {
                                _in_action = false;
                        
                                #region <<action>>
                                
                                var _content = [];
                                
                                #region Break down string into tokens
                                
                                //show_debug_message("Working on \"" + _string + "\"");
                                
                                var _in_string = false;
                                var _in_symbol = false;
                                
                                _string += " ";
                                var _work_length = string_length(_string);
                                var _work_char = "";
                                var _work_char_prev = "";
                                var _work_read_prev = 1;
                                for(var _work_read = 1; _work_read <= _work_length; _work_read++)
                                {
                                    var _read = false;
                                    var _read_add_char = 0;
                                    var _read_parse_operator = false;
                                    
                                    _work_char_prev = _work_char;
                                    var _work_char = string_char_at(_string, _work_read);
                                    
                                    if (_in_string)
                                    {
                                        //Ignore all behaviours until we hit a quote mark
                                        if (_work_char == "\"") && (_work_char_prev != "\\")
                                        {
                                            _read_add_char = 1; //Make sure we get the quote mark in the string
                                            _in_string = false;
                                            _read = true;
                                            //show_debug_message("  found closing quote mark");
                                        }
                                    }
                                    else if (_work_char == "\"") && (_work_char_prev != "\\")
                                    {
                                        //If we've got an unescaped quote mark, start a string
                                        _in_string = true;
                                        _read = true;
                                        //show_debug_message("  found open quote mark");
                                    }
                                    else if (_work_char == "!")
                                         || (_work_char == "=")
                                         || (_work_char == "<")
                                         || (_work_char == ">")
                                         || (_work_char == "+")
                                         || (_work_char == "-")
                                         || (_work_char == "*")
                                         || (_work_char == "/")
                                         || (_work_char == "&")
                                         || (_work_char == "|")
                                         || (_work_char == "^")
                                         || (_work_char == "`")
                                    {
                                        if (!_in_symbol)
                                        {
                                            //If we've found an operator symbol then do a standard read and begin reading a symbol
                                            _in_symbol = true;
                                            _read = true;
                                            //show_debug_message("  found symbol start");
                                        }
                                    }
                                    else if (_in_symbol)
                                    {
                                        //If we're reading a symbol but this character *isn't* a symbol character, do a read
                                        _in_symbol = false;
                                        _read = true;
                                        _read_parse_operator = true;
                                        //show_debug_message("  found symbol end");
                                    }
                                    else if (_work_char == " ")
                                         || (_work_char == ",")
                                    {
                                        //Always read at spaces and commas
                                        _read = true;
                                        //show_debug_message("  found space or comma");
                                    }
                                    else if (_work_char == "(") || (_work_char == ")")
                                    {
                                        //Always read at brackets
                                        _read = true;
                                        //show_debug_message("  found bracket");
                                    }
                                    else if (_work_char_prev == "(") || (_work_char_prev == ")")
                                    {
                                        //Always read at brackets
                                        _read = true;
                                        //show_debug_message("  found bracket pt.2");
                                    }
                                    
                                    if (_read)
                                    {
                                        var _out_string = string_copy(_string, _work_read_prev, _work_read + _read_add_char - _work_read_prev);
                                        //show_debug_message("    copied \"" + _out_string + "\"");
                                        _out_string = __chatterbox_remove_whitespace(_out_string, true);
                                        _out_string = __chatterbox_remove_whitespace(_out_string, false);
                                        _out_string = string_replace_all(_out_string, "\\\"", "\""); //Replace \" with "
                                        
                                        switch(_out_string)
                                        {
                                            case "and": _out_string = "&&"; break;
                                            case "&"  : _out_string = "&&"; break;
                                            case "le" : _out_string = "<";  break;
                                            case "gt" : _out_string = ">";  break;
                                            case "or" : _out_string = "||"; break;
                                            case "`"  : _out_string = "||"; break;
                                            case "|"  : _out_string = "||"; break;
                                            case "leq": _out_string = "<="; break;
                                            case "geq": _out_string = ">="; break;
                                            case "eq" : _out_string = "=="; break;
                                            case "is" : _out_string = "=="; break;
                                            case "neq": _out_string = "!="; break;
                                            case "to" : _out_string = "=";  break;
                                            case "not": _out_string = "!";  break;
                                        }
                                        
                                        if (_out_string != "")
                                        {
                                            _content[array_length_1d(_content)] = _out_string;
                                            if (array_length_1d(_content) == 1)
                                            {
                                                _content[1] = undefined; //Reserve a slot for the top-level node in the evaluation tree
                                                _content[2] = "()";      //Reserve a slot for the generic function token
                                            }
                                        }
                                        
                                        _work_read_prev = _work_read + _read_add_char;
                                    }
                                }
                                
                                #endregion
                                
                                #region Collect tokens together to make an evaluation tree
                                
                                var _content_length = array_length_1d(_content);
                                var _eval_tree_root = array_create(_content_length-3);
                                for(var _i = 3; _i < _content_length; _i++) _eval_tree_root[_i-3] = _i;
                                _content[1] = _eval_tree_root;
                                _content[2] = "()";
                                
                                var _queue = ds_list_create();
                                ds_list_add(_queue, 1);
                                
                                repeat(9999)
                                {
                                    if (ds_list_empty(_queue)) break;
                                    
                                    var _element_index = _queue[| 0];
                                    ds_list_delete(_queue, 0);
                                    
                                    var _element = _content[_element_index];
                                    if (!is_array(_element)) continue;
                                    var _element_length = array_length_1d(_element);
                                    
                                    var _break = false;
                                    for(var _op = 0; _op < global.__chatterbox_op_count; _op++)
                                    {
                                        var _operator = global.__chatterbox_op_list[| _op ];
                                        
                                        for(var _e = _element_length-1; _e > 0; _e--) //Go backwards. This solves issues with nested brackets
                                        {
                                            var _value = _content[_element[_e]];
                                            
                                            if (_value == _operator)
                                            {
                                                if (_operator == "(")
                                                {
                                                    #region Split up bracketed expressions
                                                    
                                                    //Find the first close bracket token
                                                    for(var _f = _e+1; _f < _element_length; _f++) if (_content[_element[_f]] == ")") break;
                                                    
                                                    if (_f < _element_length)
                                                    {
                                                        var _function = undefined;
                                                        if (_e > 0)
                                                        {
                                                            _function = _content[_element[_e-1]];
                                                            if (!is_string(_function) || (_function == "()") || (ds_list_find_index(global.__chatterbox_op_list, _function) >= 0)) _function = undefined;
                                                        }
                                                        
                                                        if (_function == undefined)
                                                        {
                                                            //Standard "structural" bracket
                                                            
                                                            var _new_element = [];
                                                            array_copy(_new_element, 0,   _element, _e+1, _f-_e-1);
                                                            
                                                            _content[array_length_1d(_content)] = _new_element; //Add the new sub-array to the overall content array
                                                            ds_list_add(_queue, array_length_1d(_content)-1);   //Add the index of the new sub-array to the processing queue
                                                            
                                                            _replacement_element = array_create(_element_length + _e - _f); //Create a new element array
                                                            array_copy(_replacement_element, 0,   _element, 0, _e);
                                                            _replacement_element[_e] = array_length_1d(_content)-1; //Set the index of the new sub-array in the replacement element array
                                                            array_copy(_replacement_element, _e+1,   _element, _f+1, _element_length-_f);
                                                            
                                                            _content[_element_index] = _replacement_element;
                                                            ds_list_add(_queue, _element_index); //Add the index of the replacement array to the processing queue
                                                        }
                                                        else
                                                        {
                                                            //Function call
                                                            
                                                            var _new_element = [_element[_e-1], 2];
                                                            array_copy(_new_element, 2,   _element, _e+1, _f-_e-1);
                                                            
                                                            _content[array_length_1d(_content)] = _new_element; //Add the new sub-array to the overall content array
                                                            ds_list_add(_queue, array_length_1d(_content)-1);   //Add the index of the new sub-array to the processing queue
                                                            
                                                            _replacement_element = array_create(_element_length - 1 + _e - _f); //Create a new element array
                                                            array_copy(_replacement_element, 0,   _element, 0, _e-1);
                                                            _replacement_element[_e-1] = array_length_1d(_content)-1; //Set the index of the new sub-array in the replacement element array
                                                            array_copy(_replacement_element, _e+1,   _element, _f+1, _element_length-_f);
                                                            
                                                            _content[_element_index] = _replacement_element;
                                                            ds_list_add(_queue, _element_index); //Add the index of the replacement array to the processing queue
                                                        }
                                                    }
                                                    else
                                                    {
                                                        //Error!
                                                        show_error("Chatterbox:\nSyntax error\n ", false);
                                                        _content[_element_index] = undefined;
                                                    }
                                                    
                                                    #endregion
                                                }
                                                else if (_operator == "!") || ((_operator == "-") && (_op == global.__chatterbox_negative_op_index))
                                                {
                                                    #region Unary operators
                                                    
                                                    if (_e < _element_length-1) //For a unary operator, we cannot be the last element
                                                    {
                                                        var _new_element = [];
                                                        array_copy(_new_element, 0,   _element, _e, 2);
                                                        
                                                        _content[array_length_1d(_content)] = _new_element; //Add the new sub-array to the overall content array
                                                        ds_list_add(_queue, array_length_1d(_content)-1);   //Add the index of the new sub-array to the processing queue
                                                        
                                                        _replacement_element = array_create(_element_length-1); //Create a new element array
                                                        array_copy(_replacement_element, 0,   _element, 0, _e);
                                                        _replacement_element[_e] = array_length_1d(_content)-1; //Set the index of the new sub-array in the replacement element array
                                                        array_copy(_replacement_element, _e+1,   _element, _e+2, _element_length-(_e+2));
                                                        
                                                        _content[_element_index] = _replacement_element;
                                                        ds_list_add(_queue, _element_index); //Add the index of the replacement array to the processing queue
                                                    }
                                                    else
                                                    {
                                                        //Error!
                                                        show_error("Chatterbox:\nSyntax error\n ", false);
                                                        _content[_element_index] = undefined;
                                                    }
                                                    
                                                    #endregion
                                                }
                                                else
                                                {
                                                    #region Binary operators
                                                    
                                                    if (_element_length < 3) //For a binary operator, we need at least three tokens in the array
                                                    {
                                                        if !((_operator == "-") && (_op == 8) && (_e == 0)) //Don't report this error if the subtraction sign might be a negative sign
                                                        {
                                                            //Error!
                                                            show_error("Chatterbox:\nSyntax error\n ", false);
                                                            _content[_element_index] = undefined;
                                                        }
                                                    }
                                                    else if (_e <= 0) || (_e >= _element_length-1) //A binary operator must be in-between two tokens
                                                    {
                                                        if !((_operator == "-") && (_op == 8) && (_e == 0)) //Don't report this error if the subtraction sign might be a negative sign
                                                        {
                                                            //Error!
                                                            show_error("Chatterbox:\nSyntax error\n ", false);
                                                            _content[_element_index] = undefined;
                                                        }
                                                    }
                                                    else if (_element_length > 3)
                                                    {
                                                        var _replacement_element = [_element[0],
                                                                                    _element[_e],
                                                                                    _element[_element_length-1]];
                                                        
                                                        //Split up the left-hand side of the array
                                                        if (_e > 1)
                                                        {
                                                            var _new_element = [];
                                                            array_copy(_new_element, 0,   _element, 0, _e);
                                                            
                                                            _content[array_length_1d(_content)] = _new_element;    //Add the new sub-array to the overall content array
                                                            ds_list_add(_queue, array_length_1d(_content)-1);      //Add the index of the new sub-array to the processing queue
                                                            _replacement_element[0] = array_length_1d(_content)-1; //Set the index of the new sub-array in the replacement element array
                                                        }
                                                        
                                                        //Split up the right-hand side of the array
                                                        if (_e < _element_length-2)
                                                        {
                                                            
                                                            var _new_element = [];
                                                            array_copy(_new_element, 0,   _element, _e+1, _element_length-_e-1);
                                                            
                                                            _content[array_length_1d(_content)] = _new_element;    //Add the new sub-array to the overall content array
                                                            ds_list_add(_queue, array_length_1d(_content)-1);      //Add the index of the new sub-array to the processing queue
                                                            _replacement_element[2] = array_length_1d(_content)-1; //Set the index of the new sub-array in the replacement element array
                                                        }
                                                        
                                                        _content[_element_index] = _replacement_element;
                                                    }
                                                    else
                                                    {
                                                        //No action needed
                                                    }
                                                    
                                                    #endregion
                                                }
                                                
                                                _break = true;
                                                break;
                                            }
                                        }
                                        
                                        if (_break) break;
                                    }
                                }
                                
                                ds_list_destroy(_queue);
                                
                                #endregion
                                
                                #region Add instruction based on content array
                                
                                if (_content[0] == "if")
                                {
                                    if (_first_token)
                                    {
                                        //If-statement on its own on a line
                                        _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_IF;
                                        _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = _content;
                                    }
                                    else
                                    {
                                        //If-statement suffixed to another token
                                        var _insert_array = array_create(__CHATTERBOX_INSTRUCTION.__SIZE);
                                        _insert_array[ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_IF;
                                        _insert_array[ __CHATTERBOX_INSTRUCTION.INDENT  ] = _indent;
                                        _insert_array[ __CHATTERBOX_INSTRUCTION.CONTENT ] = _content;
                                        ds_list_insert(global.__chatterbox_vm, ds_list_size(global.__chatterbox_vm)-1, _insert_array);
                                        
                                        _array[@ __CHATTERBOX_INSTRUCTION.TYPE ] = __CHATTERBOX_VM_IF_END;
                                    }
                                }
                                else if (_content[0] == "elseif")
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_ELSEIF;
                                    _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = _content;
                                }
                                else if (_content[0] == "set")
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_SET;
                                    _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = _content;
                                }
                                else if (_content[0] == "endif")
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE ] = __CHATTERBOX_VM_IF_END;
                                }
                                else if (_content[0] == "else")
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE ] = __CHATTERBOX_VM_ELSE;
                                }
                                else if (_content[0] == "stop")
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE ] = __CHATTERBOX_VM_STOP;
                                }
                                else if (_content[0] == "wait")
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE ] = __CHATTERBOX_VM_WAIT;
                                }
                                else if (ds_map_exists(global.__chatterbox_actions, _content[0]))
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_CUSTOM_ACTION;
                                    _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = _content;
                                }
                                else
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_GENERIC_ACTION;
                                    _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = [_string];
                                }
                                
                                #endregion
                        
                                #endregion
                            }
                            else
                            {
                                #region Text
                        
                                if (string_copy(_string, 1, 2) == "->")
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_SHORTCUT;
                                    _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = [__chatterbox_remove_whitespace(string_delete(_string, 1, 2), true)];
                                }
                                else
                                {
                                    _array[@ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_TEXT;
                                    _array[@ __CHATTERBOX_INSTRUCTION.CONTENT ] = [_string];
                                }
                        
                                #endregion
                            }
                            
                            ds_list_add(global.__chatterbox_vm, _array);
                            _first_token = false;
                        }
                    }
                    
                    if (_line_char_prev == CHATTERBOX_OPTION_OPEN_DELIMITER) && (_line_char == CHATTERBOX_OPTION_OPEN_DELIMITER)
                    {
                        _in_option = true;
                    }
                    else if (_line_char_prev == CHATTERBOX_ACTION_OPEN_DELIMITER) && (_line_char == CHATTERBOX_ACTION_OPEN_DELIMITER)
                    {
                        _in_action = true;
                    }
                }
            }
        }
        
        #endregion
        
        //Make sure we always have an STOP instruction at the end
        var _array = array_create(__CHATTERBOX_INSTRUCTION.__SIZE);
        _array[ __CHATTERBOX_INSTRUCTION.TYPE    ] = __CHATTERBOX_VM_STOP;
        _array[ __CHATTERBOX_INSTRUCTION.INDENT  ] = 0;
        _array[ __CHATTERBOX_INSTRUCTION.CONTENT ] = undefined;
        ds_list_add(global.__chatterbox_vm, _array);
        
        
        
        //Debug output that enumerates all instructions for this node
        if (CHATTERBOX_DEBUG_PARSER)
        {
            var _i = _instruction_node_offset;
            repeat(ds_list_size(global.__chatterbox_vm) - _instruction_node_offset)
            {
                var _array = global.__chatterbox_vm[| _i];
                
                if (is_array(_array))
                {
                    _string = "";
                    
                    var _type    = _array[ __CHATTERBOX_INSTRUCTION.TYPE    ];
                    var _indent  = _array[ __CHATTERBOX_INSTRUCTION.INDENT  ];
                    var _content = _array[ __CHATTERBOX_INSTRUCTION.CONTENT ];
                    
                    repeat(_indent) _string += " ";
                    _string += string(_type) + ": " + string(_content);
                }
                else
                {
                    _string = string(_array);
                }
                
                show_debug_message("Chatterbox:       " + _string);
                
                _i++;
            }
        }
    }
    
    _name = ds_map_find_next(global.__chatterbox_file_data, _name);
    ds_map_destroy(_yarn_json);
}



show_debug_message("Chatterbox: VM has " + string(ds_list_size(global.__chatterbox_vm)) + " instructions");
show_debug_message("Chatterbox: Initialisation complete, took " + string((get_timer() - _timer)/1000) + "ms");
show_debug_message("Chatterbox: Thanks for using Chatterbox!");

global.__chatterbox_init_complete = true;