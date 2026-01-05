defmodule Deflate do
  @moduledoc """
  Pure Elixir implementation of DEFLATE (RFC 1951) and zlib (RFC 1950) decompression.

  Optimized with compile-time Huffman lookup tables and packed integer O(1) symbol lookup.
  Uses packed integers (symbol << 4 | len) to avoid tuple allocation in hot loops.
  """

  import Bitwise

  # Force inlining of hot path functions
  @compile {:inline, huff_loop: 6, huff_backref: 7, copy_match: 3}

  @block_stored 0
  @block_fixed 1
  @block_dynamic 2

  @length_extra_bits {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5,
                      5, 5, 5, 0}
  @length_base {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
                99, 115, 131, 163, 195, 227, 258}

  @dist_extra_bits {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11,
                    11, 12, 12, 13, 13}
  @dist_base {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
              1537, 2049, 3073, 4097, 6145, 8193, 12_289, 16_385, 24_577}

  @code_length_order {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

  @fixed_lit_lengths (List.duplicate(8, 144) ++
                        List.duplicate(9, 112) ++
                        List.duplicate(7, 24) ++
                        List.duplicate(8, 8))
                     |> List.to_tuple()

  @fixed_dist_lengths List.duplicate(5, 32) |> List.to_tuple()

  # Sentinel value for invalid lookup (impossible packed value)
  @invalid_entry -1

  # Pre-compute fixed Huffman lookup tables at compile time
  # Tables store packed integers: (symbol << 4) | len to avoid tuple allocation
  @fixed_lit_table (
                     lengths_list = for i <- 0..287, do: elem(@fixed_lit_lengths, i)
                     max_bits = 9

                     bl_count =
                       for len <- 0..max_bits, do: Enum.count(lengths_list, &(&1 == len))

                     bl_count = List.to_tuple(bl_count)

                     {next_code, _} =
                       Enum.reduce(1..max_bits, {%{}, 0}, fn bits, {codes, code} ->
                         code = Bitwise.<<<(code + elem(bl_count, bits - 1), 1)
                         {Map.put(codes, bits, code), code}
                       end)

                     {code_map, _} =
                       Enum.reduce(Enum.with_index(lengths_list), {%{}, next_code}, fn
                         {0, _sym}, {map, nc} ->
                           {map, nc}

                         {len, sym}, {map, nc} ->
                           code = Map.get(nc, len, 0)
                           nc = Map.put(nc, len, code + 1)

                           reversed =
                             Enum.reduce(1..len, {code, 0}, fn _, {v, acc} ->
                               {Bitwise.>>>(v, 1),
                                Bitwise.|||(Bitwise.<<<(acc, 1), Bitwise.&&&(v, 1))}
                             end)
                             |> elem(1)

                           {Map.put(map, {reversed, len}, sym), nc}
                       end)

                     entries =
                       for pattern <- 0..511 do
                         Enum.find_value(1..max_bits, fn len ->
                           mask = (1 <<< len) - 1
                           code = pattern &&& mask

                           case Map.get(code_map, {code, len}) do
                             nil -> nil
                             # Pack as (symbol << 4) | len
                             symbol -> Bitwise.|||(Bitwise.<<<(symbol, 4), len)
                           end
                         end) || -1
                       end

                     List.to_tuple(entries)
                   )

  @fixed_dist_table (
                      lengths_list = for i <- 0..31, do: elem(@fixed_dist_lengths, i)
                      max_bits = 5

                      bl_count =
                        for len <- 0..max_bits, do: Enum.count(lengths_list, &(&1 == len))

                      bl_count = List.to_tuple(bl_count)

                      {next_code, _} =
                        Enum.reduce(1..max_bits, {%{}, 0}, fn bits, {codes, code} ->
                          code = Bitwise.<<<(code + elem(bl_count, bits - 1), 1)
                          {Map.put(codes, bits, code), code}
                        end)

                      {code_map, _} =
                        Enum.reduce(Enum.with_index(lengths_list), {%{}, next_code}, fn
                          {0, _sym}, {map, nc} ->
                            {map, nc}

                          {len, sym}, {map, nc} ->
                            code = Map.get(nc, len, 0)
                            nc = Map.put(nc, len, code + 1)

                            reversed =
                              Enum.reduce(1..len, {code, 0}, fn _, {v, acc} ->
                                {Bitwise.>>>(v, 1),
                                 Bitwise.|||(Bitwise.<<<(acc, 1), Bitwise.&&&(v, 1))}
                              end)
                              |> elem(1)

                            {Map.put(map, {reversed, len}, sym), nc}
                        end)

                      entries =
                        for pattern <- 0..31 do
                          Enum.find_value(1..max_bits, fn len ->
                            mask = (1 <<< len) - 1
                            code = pattern &&& mask

                            case Map.get(code_map, {code, len}) do
                              nil -> nil
                              # Pack as (symbol << 4) | len
                              symbol -> Bitwise.|||(Bitwise.<<<(symbol, 4), len)
                            end
                          end) || -1
                        end

                      List.to_tuple(entries)
                    )

  @spec inflate(binary()) :: {:ok, binary(), non_neg_integer()} | {:error, term()}
  def inflate(data) when byte_size(data) < 2, do: {:error, :truncated}

  def inflate(<<cmf, flg, rest::binary>>) do
    with :ok <- validate_compression_method(cmf),
         :ok <- validate_header_checksum(cmf, flg),
         :ok <- validate_no_preset_dict(flg),
         {:ok, decompressed, raw_consumed} <- inflate_raw(rest),
         :ok <- validate_adler32_present(rest, raw_consumed) do
      {:ok, decompressed, 2 + raw_consumed + 4}
    end
  end

  defp validate_compression_method(cmf) do
    cm = cmf &&& 0x0F
    if cm == 8, do: :ok, else: {:error, {:invalid_compression_method, cm}}
  end

  defp validate_header_checksum(cmf, flg) do
    if rem(cmf * 256 + flg, 31) == 0, do: :ok, else: {:error, :invalid_header_checksum}
  end

  defp validate_no_preset_dict(flg) do
    if (flg &&& 0x20) == 0, do: :ok, else: {:error, :preset_dictionary_not_supported}
  end

  defp validate_adler32_present(rest, raw_consumed) do
    if byte_size(rest) - raw_consumed >= 4, do: :ok, else: {:error, :missing_adler32}
  end

  @spec inflate_raw(binary()) :: {:ok, binary(), non_neg_integer()} | {:error, term()}
  def inflate_raw(data) do
    case inflate_loop(data, 0, 0, <<>>, false) do
      {:ok, byte_off, bit_off, output} ->
        consumed = if bit_off == 0, do: byte_off, else: byte_off + 1
        {:ok, output, consumed}

      {:error, _} = err ->
        err
    end
  end

  # Maximum back-reference distance in DEFLATE
  @window_size 32768
  # Flush chunks when buffer exceeds this size
  @flush_threshold 8192

  @doc """
  Decompress zlib data with streaming output.

  Instead of building up the entire decompressed output in memory, calls the
  provided callback function with chunks as they are decompressed. This is
  useful for:

  - Computing hashes without holding full content in memory
  - Streaming to storage/network
  - Processing very large files

  The callback receives chunks of decompressed data and an accumulator,
  returning the new accumulator value.

  ## Example: Streaming SHA-256

      hasher = :crypto.hash_init(:sha256)

      {:ok, final_hasher, bytes_consumed} = Deflate.inflate_stream(compressed, hasher, fn chunk, h ->
        :crypto.hash_update(h, chunk)
      end)

      hash = :crypto.hash_final(final_hasher)

  ## Example: Stream to file

      {:ok, file} = File.open("output.bin", [:write, :binary])

      {:ok, _, _} = Deflate.inflate_stream(compressed, nil, fn chunk, _ ->
        IO.binwrite(file, chunk)
        nil
      end)

      File.close(file)

  Returns `{:ok, final_accumulator, bytes_consumed}` or `{:error, reason}`.
  """
  @spec inflate_stream(binary(), acc, (binary(), acc -> acc)) ::
          {:ok, acc, non_neg_integer()} | {:error, term()}
        when acc: any()
  def inflate_stream(data, _initial_acc, _callback) when byte_size(data) < 2 do
    # Need at least 2 bytes for zlib header
    {:error, :truncated}
  end

  def inflate_stream(<<cmf, flg, rest::binary>>, initial_acc, callback)
      when is_function(callback, 2) do
    with :ok <- validate_compression_method(cmf),
         :ok <- validate_header_checksum(cmf, flg),
         :ok <- validate_no_preset_dict(flg),
         {:ok, final_acc, raw_consumed} <- inflate_raw_stream(rest, initial_acc, callback),
         :ok <- validate_adler32_present(rest, raw_consumed) do
      {:ok, final_acc, 2 + raw_consumed + 4}
    end
  end

  @doc """
  Decompress raw DEFLATE data with streaming output.

  Like `inflate_stream/3` but for raw DEFLATE data without zlib wrapper.
  """
  @spec inflate_raw_stream(binary(), acc, (binary(), acc -> acc)) ::
          {:ok, acc, non_neg_integer()} | {:error, term()}
        when acc: any()
  def inflate_raw_stream(data, initial_acc, callback) when is_function(callback, 2) do
    # Window buffer for back-references, accumulator for callback
    state = {<<>>, initial_acc, callback}

    case inflate_loop_stream(data, 0, 0, state, false) do
      {:ok, byte_off, bit_off, {window, acc, _callback}} ->
        # Flush any remaining data in window
        final_acc = if byte_size(window) > 0, do: callback.(window, acc), else: acc
        consumed = if bit_off == 0, do: byte_off, else: byte_off + 1
        {:ok, final_acc, consumed}

      {:error, _} = err ->
        err
    end
  end

  # Streaming version of inflate_loop
  defp inflate_loop_stream(_data, byte_off, bit_off, state, true) do
    {:ok, byte_off, bit_off, state}
  end

  defp inflate_loop_stream(data, byte_off, bit_off, state, false) do
    case read_bits(data, byte_off, bit_off, 3) do
      {:ok, header, byte_off, bit_off} ->
        bfinal = header &&& 1
        btype = header >>> 1

        case process_block_stream(data, byte_off, bit_off, state, btype) do
          {:ok, byte_off, bit_off, state} ->
            inflate_loop_stream(data, byte_off, bit_off, state, bfinal == 1)

          error ->
            error
        end

      error ->
        error
    end
  end

  defp process_block_stream(data, byte_off, bit_off, state, @block_stored) do
    byte_off = if bit_off == 0, do: byte_off, else: byte_off + 1
    read_stored_block_stream(data, byte_off, state)
  end

  defp process_block_stream(data, byte_off, bit_off, state, @block_fixed) do
    decode_huffman_stream(
      data,
      byte_off,
      bit_off,
      state,
      @fixed_lit_table,
      @fixed_dist_table,
      9,
      5
    )
  end

  defp process_block_stream(data, byte_off, bit_off, state, @block_dynamic) do
    with {:ok, hlit, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 5),
         {:ok, hdist, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 5),
         {:ok, hclen, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 4) do
      num_lit = hlit + 257
      num_dist = hdist + 1
      num_cl = hclen + 4

      case read_cl_lengths(data, byte_off, bit_off, num_cl) do
        {:ok, cl_lengths, byte_off, bit_off} ->
          cl_table = build_table(cl_lengths, 19, 7)

          case read_code_lengths(data, byte_off, bit_off, cl_table, 7, num_lit + num_dist, []) do
            {:ok, all_lengths, byte_off, bit_off} ->
              lit_lengths = Enum.take(all_lengths, num_lit) |> List.to_tuple()
              dist_lengths = Enum.drop(all_lengths, num_lit) |> List.to_tuple()

              lit_max = Enum.max(Tuple.to_list(lit_lengths))
              dist_max = Enum.max(Tuple.to_list(dist_lengths))

              lit_table = build_table(lit_lengths, num_lit, min(lit_max, 15))
              dist_table = build_table(dist_lengths, num_dist, min(dist_max, 15))

              decode_huffman_stream(
                data,
                byte_off,
                bit_off,
                state,
                lit_table,
                dist_table,
                min(lit_max, 15),
                min(dist_max, 15)
              )

            error ->
              error
          end

        error ->
          error
      end
    end
  end

  defp process_block_stream(_data, _byte_off, _bit_off, _state, 3) do
    {:error, :reserved_block_type}
  end

  defp read_stored_block_stream(data, byte_off, {window, acc, callback} = _state) do
    data_size = byte_size(data)

    with :ok <- ensure_bytes(byte_off + 4, data_size),
         <<_::binary-size(byte_off), len::little-16, nlen::little-16, _::binary>> = data,
         :ok <- validate_stored_len(len, nlen),
         start = byte_off + 4,
         :ok <- ensure_bytes(start + len, data_size) do
      chunk = binary_part(data, start, len)
      # Add to window and maybe flush
      {new_window, new_acc} = add_to_window_stream(window, chunk, acc, callback)
      {:ok, start + len, 0, {new_window, new_acc, callback}}
    end
  end

  # Add data to window buffer, flush if over threshold
  defp add_to_window_stream(window, chunk, acc, callback) do
    new_window = <<window::binary, chunk::binary>>
    window_size = byte_size(new_window)

    if window_size > @flush_threshold + @window_size do
      # Flush everything except last 32KB needed for back-refs
      flush_size = window_size - @window_size
      to_flush = binary_part(new_window, 0, flush_size)
      keep = binary_part(new_window, flush_size, @window_size)
      new_acc = callback.(to_flush, acc)
      {keep, new_acc}
    else
      {new_window, acc}
    end
  end

  # Streaming Huffman decoder
  defp decode_huffman_stream(data, byte_off, bit_off, state, lt, dt, lb, db) do
    <<_::binary-size(byte_off), rest::bits>> = data
    tables = {lt, dt, lb, db}

    case rest do
      <<b0, more::bits>> when bit_off > 0 ->
        buffer = b0 >>> bit_off
        bits_avail = 8 - bit_off
        bytes_read = byte_off + 1
        huff_loop_stream(more, buffer, bits_avail, bytes_read, state, tables)

      <<b0, b1, more::bits>> ->
        buffer = b0 ||| b1 <<< 8
        huff_loop_stream(more, buffer, 16, byte_off + 2, state, tables)

      <<b0, more::bits>> ->
        huff_loop_stream(more, b0, 8, byte_off + 1, state, tables)

      <<>> ->
        huff_loop_stream(<<>>, 0, 0, byte_off, state, tables)
    end
  end

  # Refill buffer when low
  defp huff_loop_stream(<<b0, b1, rest::bits>>, buf, avail, read, state, tables) when avail < 9 do
    new_buf = buf ||| b0 <<< avail ||| b1 <<< (avail + 8)
    huff_loop_stream(rest, new_buf, avail + 16, read + 2, state, tables)
  end

  defp huff_loop_stream(<<b0, rest::bits>>, buf, avail, read, state, tables) when avail < 9 do
    new_buf = buf ||| b0 <<< avail
    huff_loop_stream(rest, new_buf, avail + 8, read + 1, state, tables)
  end

  # Main streaming decode loop
  defp huff_loop_stream(
         rest,
         buf,
         avail,
         read,
         {window, acc, callback} = state,
         {lt, _dt, lb, _db} = tables
       ) do
    index = buf &&& (1 <<< lb) - 1
    packed = elem(lt, index)

    cond do
      packed == @invalid_entry ->
        {:error, :invalid_huffman_code}

      packed < 4097 ->
        # Literal byte
        symbol = packed >>> 4
        len = packed &&& 0xF
        {new_window, new_acc} = add_to_window_stream(window, <<symbol>>, acc, callback)

        huff_loop_stream(
          rest,
          buf >>> len,
          avail - len,
          read,
          {new_window, new_acc, callback},
          tables
        )

      packed < 4112 ->
        # End of block
        len = packed &&& 0xF
        remaining_bits = avail - len
        total_bits_consumed = read * 8 - remaining_bits
        final_byte = div(total_bits_consumed, 8)
        final_bit = rem(total_bits_consumed, 8)
        {:ok, final_byte, final_bit, state}

      true ->
        # Back-reference
        symbol = packed >>> 4
        len = packed &&& 0xF
        new_buf = buf >>> len
        new_avail = avail - len
        huff_backref_stream(rest, new_buf, new_avail, read, state, symbol, tables)
    end
  end

  # Handle empty rest
  defp huff_loop_stream(
         <<>>,
         buf,
         avail,
         read,
         {window, acc, callback} = state,
         {lt, _dt, lb, _db} = tables
       )
       when avail >= lb do
    index = buf &&& (1 <<< lb) - 1
    packed = elem(lt, index)

    cond do
      packed == @invalid_entry ->
        {:error, :invalid_huffman_code}

      packed < 4097 ->
        symbol = packed >>> 4
        len = packed &&& 0xF
        {new_window, new_acc} = add_to_window_stream(window, <<symbol>>, acc, callback)

        huff_loop_stream(
          <<>>,
          buf >>> len,
          avail - len,
          read,
          {new_window, new_acc, callback},
          tables
        )

      packed < 4112 ->
        len = packed &&& 0xF
        remaining_bits = avail - len
        total_bits_consumed = read * 8 - remaining_bits
        final_byte = div(total_bits_consumed, 8)
        final_bit = rem(total_bits_consumed, 8)
        {:ok, final_byte, final_bit, state}

      true ->
        symbol = packed >>> 4
        len = packed &&& 0xF
        new_buf = buf >>> len
        new_avail = avail - len
        huff_backref_stream(<<>>, new_buf, new_avail, read, state, symbol, tables)
    end
  end

  defp huff_loop_stream(<<>>, _buf, _avail, _read, _state, _tables) do
    {:error, :unexpected_end_of_data}
  end

  # Back-reference handling for streaming
  defp huff_backref_stream(<<b0, b1, rest::bits>>, buf, avail, read, state, sym, tables)
       when avail < 15 do
    new_buf = buf ||| b0 <<< avail ||| b1 <<< (avail + 8)
    huff_backref_stream(rest, new_buf, avail + 16, read + 2, state, sym, tables)
  end

  defp huff_backref_stream(<<b0, rest::bits>>, buf, avail, read, state, sym, tables)
       when avail < 15 do
    new_buf = buf ||| b0 <<< avail
    huff_backref_stream(rest, new_buf, avail + 8, read + 1, state, sym, tables)
  end

  defp huff_backref_stream(
         rest,
         buf,
         avail,
         read,
         {window, acc, callback},
         symbol,
         {_lt, dt, _lb, db} = tables
       ) do
    len_code = symbol - 257
    extra_bits = elem(@length_extra_bits, len_code)
    base_len = elem(@length_base, len_code)

    extra = buf &&& (1 <<< extra_bits) - 1
    buf = buf >>> extra_bits
    avail = avail - extra_bits
    length = base_len + extra

    dist_index = buf &&& (1 <<< db) - 1
    dist_packed = elem(dt, dist_index)

    if dist_packed == @invalid_entry do
      {:error, :invalid_huffman_code}
    else
      dist_code = dist_packed >>> 4
      dist_len = dist_packed &&& 0xF

      if dist_code > 29 do
        {:error, :invalid_distance_code}
      else
        buf = buf >>> dist_len
        avail = avail - dist_len

        dist_extra_bits = elem(@dist_extra_bits, dist_code)
        dist_base = elem(@dist_base, dist_code)
        dextra = buf &&& (1 <<< dist_extra_bits) - 1
        buf = buf >>> dist_extra_bits
        avail = avail - dist_extra_bits

        distance = dist_base + dextra

        # Copy from window (back-reference)
        copied = copy_from_window(window, distance, length)
        {new_window, new_acc} = add_to_window_stream(window, copied, acc, callback)
        huff_loop_stream(rest, buf, avail, read, {new_window, new_acc, callback}, tables)
      end
    end
  end

  defp huff_backref_stream(<<>>, buf, avail, read, state, symbol, tables) when avail >= 15 do
    huff_backref_stream_process(buf, avail, read, state, symbol, tables)
  end

  defp huff_backref_stream(<<>>, _buf, _avail, _read, _state, _sym, _tables) do
    {:error, :unexpected_end_of_data}
  end

  defp huff_backref_stream_process(
         buf,
         avail,
         read,
         {window, acc, callback},
         symbol,
         {_lt, dt, _lb, db} = tables
       ) do
    len_code = symbol - 257
    extra_bits = elem(@length_extra_bits, len_code)
    base_len = elem(@length_base, len_code)

    extra = buf &&& (1 <<< extra_bits) - 1
    buf = buf >>> extra_bits
    avail = avail - extra_bits
    length = base_len + extra

    dist_index = buf &&& (1 <<< db) - 1
    dist_packed = elem(dt, dist_index)

    if dist_packed == @invalid_entry do
      {:error, :invalid_huffman_code}
    else
      dist_code = dist_packed >>> 4
      dist_len = dist_packed &&& 0xF

      if dist_code > 29 do
        {:error, :invalid_distance_code}
      else
        buf = buf >>> dist_len
        avail = avail - dist_len

        dist_extra_bits = elem(@dist_extra_bits, dist_code)
        dist_base = elem(@dist_base, dist_code)
        dextra = buf &&& (1 <<< dist_extra_bits) - 1
        buf = buf >>> dist_extra_bits
        avail = avail - dist_extra_bits

        distance = dist_base + dextra
        copied = copy_from_window(window, distance, length)
        {new_window, new_acc} = add_to_window_stream(window, copied, acc, callback)
        huff_loop_stream(<<>>, buf, avail, read, {new_window, new_acc, callback}, tables)
      end
    end
  end

  # Copy from window for back-references (handles overlapping copies)
  defp copy_from_window(window, distance, length) do
    window_size = byte_size(window)
    start = window_size - distance

    if distance >= length do
      binary_part(window, start, length)
    else
      # Overlapping copy - need to repeat pattern
      pattern = binary_part(window, start, distance)
      build_pattern(pattern, length, <<>>)
    end
  end

  # Main loop - byte_off and bit_off track exact position
  defp inflate_loop(_data, byte_off, bit_off, output, true) do
    {:ok, byte_off, bit_off, output}
  end

  defp inflate_loop(data, byte_off, bit_off, output, false) do
    case read_bits(data, byte_off, bit_off, 3) do
      {:ok, header, byte_off, bit_off} ->
        bfinal = header &&& 1
        btype = header >>> 1

        case process_block(data, byte_off, bit_off, output, btype) do
          {:ok, byte_off, bit_off, output} ->
            inflate_loop(data, byte_off, bit_off, output, bfinal == 1)

          error ->
            error
        end

      error ->
        error
    end
  end

  defp process_block(data, byte_off, bit_off, output, @block_stored) do
    # Align to byte boundary
    byte_off = if bit_off == 0, do: byte_off, else: byte_off + 1
    read_stored_block(data, byte_off, output)
  end

  defp process_block(data, byte_off, bit_off, output, @block_fixed) do
    decode_huffman(data, byte_off, bit_off, output, @fixed_lit_table, @fixed_dist_table, 9, 5)
  end

  defp process_block(data, byte_off, bit_off, output, @block_dynamic) do
    with {:ok, hlit, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 5),
         {:ok, hdist, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 5),
         {:ok, hclen, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 4) do
      num_lit = hlit + 257
      num_dist = hdist + 1
      num_cl = hclen + 4

      case read_cl_lengths(data, byte_off, bit_off, num_cl) do
        {:ok, cl_lengths, byte_off, bit_off} ->
          cl_table = build_table(cl_lengths, 19, 7)

          case read_code_lengths(data, byte_off, bit_off, cl_table, 7, num_lit + num_dist, []) do
            {:ok, all_lengths, byte_off, bit_off} ->
              lit_lengths = Enum.take(all_lengths, num_lit) |> List.to_tuple()
              dist_lengths = Enum.drop(all_lengths, num_lit) |> List.to_tuple()

              lit_max = Enum.max(Tuple.to_list(lit_lengths))
              dist_max = Enum.max(Tuple.to_list(dist_lengths))

              lit_table = build_table(lit_lengths, num_lit, min(lit_max, 15))
              dist_table = build_table(dist_lengths, num_dist, min(dist_max, 15))

              decode_huffman(
                data,
                byte_off,
                bit_off,
                output,
                lit_table,
                dist_table,
                min(lit_max, 15),
                min(dist_max, 15)
              )

            error ->
              error
          end

        error ->
          error
      end
    end
  end

  defp process_block(_data, _byte_off, _bit_off, _output, 3) do
    {:error, :reserved_block_type}
  end

  # Stored block helpers
  defp read_stored_block(data, byte_off, output) do
    data_size = byte_size(data)

    with :ok <- ensure_bytes(byte_off + 4, data_size),
         <<_::binary-size(byte_off), len::little-16, nlen::little-16, _::binary>> = data,
         :ok <- validate_stored_len(len, nlen),
         start = byte_off + 4,
         :ok <- ensure_bytes(start + len, data_size) do
      chunk = binary_part(data, start, len)
      {:ok, start + len, 0, <<output::binary, chunk::binary>>}
    end
  end

  defp ensure_bytes(needed, available) do
    if needed <= available, do: :ok, else: {:error, :unexpected_end_of_data}
  end

  defp validate_stored_len(len, nlen) do
    if Bitwise.bxor(len, nlen) == 0xFFFF, do: :ok, else: {:error, :invalid_stored_block_length}
  end

  # Read code length code lengths
  defp read_cl_lengths(data, byte_off, bit_off, count) do
    read_cl_lengths(data, byte_off, bit_off, count, 0, List.duplicate(0, 19))
  end

  defp read_cl_lengths(_data, byte_off, bit_off, count, idx, lengths) when idx >= count do
    {:ok, List.to_tuple(lengths), byte_off, bit_off}
  end

  defp read_cl_lengths(data, byte_off, bit_off, count, idx, lengths) do
    case read_bits(data, byte_off, bit_off, 3) do
      {:ok, len, byte_off, bit_off} ->
        pos = elem(@code_length_order, idx)
        lengths = List.replace_at(lengths, pos, len)
        read_cl_lengths(data, byte_off, bit_off, count, idx + 1, lengths)

      error ->
        error
    end
  end

  # Read Huffman code lengths using code length table
  defp read_code_lengths(_data, byte_off, bit_off, _cl_table, _cl_bits, total, acc)
       when length(acc) >= total do
    {:ok, Enum.reverse(acc) |> Enum.take(total), byte_off, bit_off}
  end

  defp read_code_lengths(data, byte_off, bit_off, cl_table, cl_bits, total, acc) do
    case decode_symbol(data, byte_off, bit_off, cl_table, cl_bits) do
      {:ok, symbol, byte_off, bit_off} when symbol <= 15 ->
        read_code_lengths(data, byte_off, bit_off, cl_table, cl_bits, total, [symbol | acc])

      {:ok, symbol, byte_off, bit_off} when symbol in [16, 17, 18] ->
        handle_repeat_code(data, byte_off, bit_off, cl_table, cl_bits, total, acc, symbol)

      error ->
        error
    end
  end

  defp handle_repeat_code(data, byte_off, bit_off, cl_table, cl_bits, total, acc, 16) do
    with {:ok, extra, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 2) do
      prev = if acc == [], do: 0, else: hd(acc)
      new_acc = List.duplicate(prev, extra + 3) ++ acc
      read_code_lengths(data, byte_off, bit_off, cl_table, cl_bits, total, new_acc)
    end
  end

  defp handle_repeat_code(data, byte_off, bit_off, cl_table, cl_bits, total, acc, 17) do
    with {:ok, extra, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 3) do
      new_acc = List.duplicate(0, extra + 3) ++ acc
      read_code_lengths(data, byte_off, bit_off, cl_table, cl_bits, total, new_acc)
    end
  end

  defp handle_repeat_code(data, byte_off, bit_off, cl_table, cl_bits, total, acc, 18) do
    with {:ok, extra, byte_off, bit_off} <- read_bits(data, byte_off, bit_off, 7) do
      new_acc = List.duplicate(0, extra + 11) ++ acc
      read_code_lengths(data, byte_off, bit_off, cl_table, cl_bits, total, new_acc)
    end
  end

  # Build runtime lookup table
  defp build_table(lengths, max_code, max_bits) when max_bits > 0 do
    lengths_list = extract_lengths(lengths, max_code)
    actual_max = Enum.max(lengths_list)
    build_table_from_lengths(lengths_list, actual_max, max_bits)
  end

  defp build_table(_lengths, _max_code, 0), do: {:invalid}

  defp extract_lengths(lengths, max_code) when is_tuple(lengths) do
    for i <- 0..(max_code - 1), do: elem(lengths, i)
  end

  defp extract_lengths(lengths, max_code), do: Enum.take(lengths, max_code)

  defp build_table_from_lengths(_lengths_list, 0, max_bits) do
    List.duplicate(@invalid_entry, 1 <<< max_bits) |> List.to_tuple()
  end

  defp build_table_from_lengths(lengths_list, actual_max, max_bits) do
    code_map = build_code_map(lengths_list, actual_max)
    table_size = 1 <<< max_bits

    entries =
      for pattern <- 0..(table_size - 1) do
        lookup_pattern(code_map, pattern, actual_max)
      end

    List.to_tuple(entries)
  end

  defp build_code_map(lengths_list, actual_max) do
    bl_count = for len <- 0..actual_max, do: Enum.count(lengths_list, &(&1 == len))
    bl_count = List.to_tuple(bl_count)

    {next_code, _} =
      Enum.reduce(1..actual_max, {%{}, 0}, fn bits, {codes, code} ->
        prev = elem(bl_count, bits - 1)
        code = (code + prev) <<< 1
        {Map.put(codes, bits, code), code}
      end)

    {code_map, _} =
      Enum.reduce(Enum.with_index(lengths_list), {%{}, next_code}, fn
        {0, _sym}, {map, nc} -> {map, nc}
        {len, sym}, {map, nc} -> add_symbol_to_map(map, nc, len, sym)
      end)

    code_map
  end

  defp add_symbol_to_map(map, nc, len, sym) do
    code = Map.get(nc, len, 0)
    nc = Map.put(nc, len, code + 1)
    reversed = reverse_bits(code, len)
    {Map.put(map, {reversed, len}, sym), nc}
  end

  defp reverse_bits(code, len) do
    Enum.reduce(1..len, {code, 0}, fn _, {v, acc} ->
      {v >>> 1, acc <<< 1 ||| (v &&& 1)}
    end)
    |> elem(1)
  end

  defp lookup_pattern(code_map, pattern, actual_max) do
    Enum.find_value(1..actual_max, fn len ->
      mask = (1 <<< len) - 1
      code = pattern &&& mask

      case Map.get(code_map, {code, len}) do
        nil -> nil
        # Pack as (symbol << 4) | len
        symbol -> symbol <<< 4 ||| len
      end
    end) || @invalid_entry
  end

  # Huffman decoding with bit buffer - binary first for match context optimization
  # We track: rest binary, buffer, bits_avail, bytes_read (from original start)
  defp decode_huffman(data, byte_off, bit_off, output, lt, dt, lb, db) do
    <<_::binary-size(byte_off), rest::bits>> = data
    tables = {lt, dt, lb, db}

    case rest do
      <<b0, more::bits>> when bit_off > 0 ->
        buffer = b0 >>> bit_off
        bits_avail = 8 - bit_off
        bytes_read = byte_off + 1
        huff_loop(more, buffer, bits_avail, bytes_read, output, tables)

      <<b0, b1, more::bits>> ->
        buffer = b0 ||| b1 <<< 8
        huff_loop(more, buffer, 16, byte_off + 2, output, tables)

      <<b0, more::bits>> ->
        huff_loop(more, b0, 8, byte_off + 1, output, tables)

      <<>> ->
        huff_loop(<<>>, 0, 0, byte_off, output, tables)
    end
  end

  # Refill buffer when low - binary FIRST for match context optimization
  defp huff_loop(<<b0, b1, rest::bits>>, buf, avail, read, out, tables) when avail < 9 do
    new_buf = buf ||| b0 <<< avail ||| b1 <<< (avail + 8)
    huff_loop(rest, new_buf, avail + 16, read + 2, out, tables)
  end

  defp huff_loop(<<b0, rest::bits>>, buf, avail, read, out, tables) when avail < 9 do
    new_buf = buf ||| b0 <<< avail
    huff_loop(rest, new_buf, avail + 8, read + 1, out, tables)
  end

  # Main decode path - direct binary append with packed integer unpacking
  defp huff_loop(rest, buf, avail, read, out, {lt, _dt, lb, _db} = tables) do
    index = buf &&& (1 <<< lb) - 1
    packed = elem(lt, index)

    # Unpack: symbol = packed >>> 4, len = packed &&& 0xF
    # Use cond for fast integer comparisons instead of tuple pattern matching
    cond do
      packed == @invalid_entry ->
        {:error, :invalid_huffman_code}

      packed < 4097 ->
        # symbol < 256 (256 << 4 = 4096), this is a literal byte
        symbol = packed >>> 4
        len = packed &&& 0xF
        huff_loop(rest, buf >>> len, avail - len, read, <<out::binary, symbol>>, tables)

      packed < 4112 ->
        # symbol == 256 (4096 <= packed < 4112), end of block
        len = packed &&& 0xF
        remaining_bits = avail - len
        total_bits_consumed = read * 8 - remaining_bits
        final_byte = div(total_bits_consumed, 8)
        final_bit = rem(total_bits_consumed, 8)
        {:ok, final_byte, final_bit, out}

      true ->
        # symbol >= 257, back-reference
        symbol = packed >>> 4
        len = packed &&& 0xF
        new_buf = buf >>> len
        new_avail = avail - len
        huff_backref(rest, new_buf, new_avail, read, out, symbol, tables)
    end
  end

  # Handle empty rest with bits still in buffer
  defp huff_loop(<<>>, buf, avail, read, out, {lt, _dt, lb, _db} = tables) when avail >= lb do
    index = buf &&& (1 <<< lb) - 1
    packed = elem(lt, index)

    cond do
      packed == @invalid_entry ->
        {:error, :invalid_huffman_code}

      packed < 4097 ->
        symbol = packed >>> 4
        len = packed &&& 0xF
        huff_loop(<<>>, buf >>> len, avail - len, read, <<out::binary, symbol>>, tables)

      packed < 4112 ->
        len = packed &&& 0xF
        remaining_bits = avail - len
        total_bits_consumed = read * 8 - remaining_bits
        final_byte = div(total_bits_consumed, 8)
        final_bit = rem(total_bits_consumed, 8)
        {:ok, final_byte, final_bit, out}

      true ->
        symbol = packed >>> 4
        len = packed &&& 0xF
        new_buf = buf >>> len
        new_avail = avail - len
        huff_backref(<<>>, new_buf, new_avail, read, out, symbol, tables)
    end
  end

  defp huff_loop(<<>>, _buf, _avail, _read, _out, _tables) do
    {:error, :unexpected_end_of_data}
  end

  # Back-reference handling with bit buffer - refill if needed
  defp huff_backref(<<b0, b1, rest::bits>>, buf, avail, read, out, sym, tables) when avail < 15 do
    new_buf = buf ||| b0 <<< avail ||| b1 <<< (avail + 8)
    huff_backref(rest, new_buf, avail + 16, read + 2, out, sym, tables)
  end

  defp huff_backref(<<b0, rest::bits>>, buf, avail, read, out, sym, tables) when avail < 15 do
    new_buf = buf ||| b0 <<< avail
    huff_backref(rest, new_buf, avail + 8, read + 1, out, sym, tables)
  end

  defp huff_backref(rest, buf, avail, read, out, symbol, {_lt, dt, _lb, db} = tables) do
    len_code = symbol - 257
    extra_bits = elem(@length_extra_bits, len_code)
    base_len = elem(@length_base, len_code)

    # Read length extra bits from buffer
    extra = buf &&& (1 <<< extra_bits) - 1
    buf = buf >>> extra_bits
    avail = avail - extra_bits
    length = base_len + extra

    # Decode distance symbol - unpack from packed integer
    dist_index = buf &&& (1 <<< db) - 1
    dist_packed = elem(dt, dist_index)

    if dist_packed == @invalid_entry do
      {:error, :invalid_huffman_code}
    else
      dist_code = dist_packed >>> 4
      dist_len = dist_packed &&& 0xF

      if dist_code > 29 do
        {:error, :invalid_distance_code}
      else
        buf = buf >>> dist_len
        avail = avail - dist_len

        # Read distance extra bits
        dist_extra_bits = elem(@dist_extra_bits, dist_code)
        dist_base = elem(@dist_base, dist_code)
        dextra = buf &&& (1 <<< dist_extra_bits) - 1
        buf = buf >>> dist_extra_bits
        avail = avail - dist_extra_bits

        distance = dist_base + dextra
        out = copy_match(out, distance, length)
        huff_loop(rest, buf, avail, read, out, tables)
      end
    end
  end

  defp huff_backref(<<>>, buf, avail, read, out, symbol, tables) when avail >= 15 do
    # Have enough bits, continue processing
    huff_backref_process(buf, avail, read, out, symbol, tables)
  end

  defp huff_backref(<<>>, _buf, _avail, _read, _out, _sym, _tables) do
    {:error, :unexpected_end_of_data}
  end

  defp huff_backref_process(buf, avail, read, out, symbol, {_lt, dt, _lb, db} = tables) do
    len_code = symbol - 257
    extra_bits = elem(@length_extra_bits, len_code)
    base_len = elem(@length_base, len_code)

    extra = buf &&& (1 <<< extra_bits) - 1
    buf = buf >>> extra_bits
    avail = avail - extra_bits
    length = base_len + extra

    dist_index = buf &&& (1 <<< db) - 1
    dist_packed = elem(dt, dist_index)

    if dist_packed == @invalid_entry do
      {:error, :invalid_huffman_code}
    else
      dist_code = dist_packed >>> 4
      dist_len = dist_packed &&& 0xF

      if dist_code > 29 do
        {:error, :invalid_distance_code}
      else
        buf = buf >>> dist_len
        avail = avail - dist_len

        dist_extra_bits = elem(@dist_extra_bits, dist_code)
        dist_base = elem(@dist_base, dist_code)
        dextra = buf &&& (1 <<< dist_extra_bits) - 1
        buf = buf >>> dist_extra_bits
        avail = avail - dist_extra_bits

        distance = dist_base + dextra
        out = copy_match(out, distance, length)
        huff_loop(<<>>, buf, avail, read, out, tables)
      end
    end
  end

  # Decode symbol using lookup table - O(1) lookup with packed integers
  defp decode_symbol(data, byte_off, bit_off, table, max_bits) do
    # Peek at max_bits bits
    case peek_bits(data, byte_off, bit_off, max_bits) do
      {:ok, bits, _available} ->
        packed = elem(table, bits)

        if packed == @invalid_entry do
          {:error, :invalid_huffman_code}
        else
          # Unpack: symbol = packed >>> 4, len = packed &&& 0xF
          symbol = packed >>> 4
          len = packed &&& 0xF
          {new_byte_off, new_bit_off} = advance_bits(byte_off, bit_off, len)
          {:ok, symbol, new_byte_off, new_bit_off}
        end

      {:error, _} = err ->
        err
    end
  end

  # Peek at bits without consuming (for table lookup)
  defp peek_bits(_data, _byte_off, _bit_off, 0) do
    {:ok, 0, 0}
  end

  defp peek_bits(data, byte_off, bit_off, count) do
    data_size = byte_size(data)
    peek_bits_acc(data, data_size, byte_off, bit_off, count, 0, 0)
  end

  defp peek_bits_acc(_data, _data_size, _byte_off, _bit_off, 0, value, shift) do
    {:ok, value, shift}
  end

  defp peek_bits_acc(_data, data_size, byte_off, _bit_off, _count, value, shift)
       when byte_off >= data_size do
    {:ok, value, shift}
  end

  defp peek_bits_acc(data, data_size, byte_off, bit_off, count, value, shift) do
    byte = :binary.at(data, byte_off)
    bits_available = 8 - bit_off
    bits_to_read = min(count, bits_available)

    mask = (1 <<< bits_to_read) - 1
    bits = byte >>> bit_off &&& mask
    value = value ||| bits <<< shift

    new_bit_off = bit_off + bits_to_read

    if new_bit_off >= 8 do
      peek_bits_acc(
        data,
        data_size,
        byte_off + 1,
        0,
        count - bits_to_read,
        value,
        shift + bits_to_read
      )
    else
      peek_bits_acc(
        data,
        data_size,
        byte_off,
        new_bit_off,
        count - bits_to_read,
        value,
        shift + bits_to_read
      )
    end
  end

  # Read and consume bits
  defp read_bits(_data, byte_off, bit_off, 0), do: {:ok, 0, byte_off, bit_off}

  defp read_bits(data, byte_off, bit_off, count) do
    read_bits_acc(data, byte_size(data), byte_off, bit_off, count, 0, 0)
  end

  defp read_bits_acc(_data, _data_size, byte_off, bit_off, 0, value, _shift) do
    {:ok, value, byte_off, bit_off}
  end

  defp read_bits_acc(_data, data_size, byte_off, _bit_off, _count, _value, _shift)
       when byte_off >= data_size do
    {:error, :unexpected_end_of_data}
  end

  defp read_bits_acc(data, data_size, byte_off, bit_off, count, value, shift) do
    byte = :binary.at(data, byte_off)
    bits_available = 8 - bit_off
    bits_to_read = min(count, bits_available)

    mask = (1 <<< bits_to_read) - 1
    bits = byte >>> bit_off &&& mask
    value = value ||| bits <<< shift

    new_bit_off = bit_off + bits_to_read

    if new_bit_off >= 8 do
      read_bits_acc(
        data,
        data_size,
        byte_off + 1,
        0,
        count - bits_to_read,
        value,
        shift + bits_to_read
      )
    else
      read_bits_acc(
        data,
        data_size,
        byte_off,
        new_bit_off,
        count - bits_to_read,
        value,
        shift + bits_to_read
      )
    end
  end

  defp advance_bits(byte_off, bit_off, count) do
    total_bits = bit_off + count
    {byte_off + div(total_bits, 8), rem(total_bits, 8)}
  end

  # Copy match - optimized
  defp copy_match(output, distance, length) when distance >= length do
    start = byte_size(output) - distance
    <<output::binary, binary_part(output, start, length)::binary>>
  end

  defp copy_match(output, distance, length) do
    start = byte_size(output) - distance
    pattern = binary_part(output, start, distance)
    <<output::binary, build_pattern(pattern, length, <<>>)::binary>>
  end

  defp build_pattern(_pattern, 0, acc), do: acc

  defp build_pattern(pattern, remaining, acc) when remaining >= byte_size(pattern) do
    build_pattern(pattern, remaining - byte_size(pattern), <<acc::binary, pattern::binary>>)
  end

  defp build_pattern(pattern, remaining, acc) do
    <<acc::binary, binary_part(pattern, 0, remaining)::binary>>
  end
end
