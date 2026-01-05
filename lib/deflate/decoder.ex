defmodule Deflate.Decoder do
  @moduledoc """
  Stateful DEFLATE decoder for chunked input.

  Use this when data arrives in chunks (e.g., from SSH packets or HTTP streaming).
  The decoder maintains state between chunks and produces output as soon as complete
  data is available.

  ## Example: SSH packet stream

      # Initialize decoder
      {:ok, decoder} = Deflate.Decoder.new()

      # Feed chunks as they arrive from network
      {:ok, output1, decoder} = Deflate.Decoder.decode(decoder, packet1)
      {:ok, output2, decoder} = Deflate.Decoder.decode(decoder, packet2)
      {:ok, output3, decoder} = Deflate.Decoder.decode(decoder, packet3)

      # When stream ends
      {:done, final_output, bytes_consumed} = Deflate.Decoder.finish(decoder)

  ## Example: Stream with callback

      {:ok, decoder} = Deflate.Decoder.new(format: :zlib, on_output: fn chunk ->
        IO.binwrite(file, chunk)
      end)

      for packet <- packets do
        {:ok, decoder} = Deflate.Decoder.decode(decoder, packet)
      end

      {:done, bytes_consumed} = Deflate.Decoder.finish(decoder)
  """

  import Bitwise

  # Block types
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

  # Pre-computed fixed Huffman tables (same as main module)
  @fixed_lit_lengths (List.duplicate(8, 144) ++
                        List.duplicate(9, 112) ++
                        List.duplicate(7, 24) ++
                        List.duplicate(8, 8))
                     |> List.to_tuple()

  @fixed_dist_lengths List.duplicate(5, 32) |> List.to_tuple()

  @invalid_entry -1
  @window_size 32768

  # Decoder state phases
  # :zlib_header - expecting zlib CMF/FLG bytes
  # :block_header - expecting BFINAL/BTYPE bits
  # :stored_len - expecting stored block LEN/NLEN
  # :stored_data - copying stored block data
  # :dynamic_header - reading dynamic Huffman table definition
  # :huffman - decoding Huffman-compressed data
  # :done - finished (hit BFINAL block end)

  defstruct [
    # Configuration
    :format,
    :on_output,
    # Input buffer
    :buffer,
    :bit_offset,
    :bytes_consumed,
    # Decode state
    :phase,
    :is_final_block,
    # Block-specific state
    :stored_remaining,
    :lit_table,
    :dist_table,
    :lit_bits,
    :dist_bits,
    # Dynamic header parsing state
    :dynamic_state,
    # Back-reference state (for resuming mid-backref)
    :backref_state,
    # Output
    :window,
    :pending_output
  ]

  @type t :: %__MODULE__{}

  @doc """
  Create a new decoder.

  ## Options

    * `:format` - `:zlib` (default) or `:raw` for raw DEFLATE without zlib wrapper
    * `:on_output` - Optional callback function `(binary -> any)` called with output chunks

  """
  @spec new(keyword()) :: {:ok, t()}
  def new(opts \\ []) do
    format = Keyword.get(opts, :format, :zlib)
    on_output = Keyword.get(opts, :on_output)

    initial_phase = if format == :zlib, do: :zlib_header, else: :block_header

    decoder = %__MODULE__{
      format: format,
      on_output: on_output,
      buffer: <<>>,
      bit_offset: 0,
      bytes_consumed: 0,
      phase: initial_phase,
      is_final_block: false,
      stored_remaining: 0,
      lit_table: nil,
      dist_table: nil,
      lit_bits: 0,
      dist_bits: 0,
      dynamic_state: nil,
      backref_state: nil,
      window: <<>>,
      pending_output: <<>>
    }

    {:ok, decoder}
  end

  @doc """
  Feed data chunk to the decoder.

  Returns `{:ok, output, decoder}` where output is decompressed data available so far.
  If using `on_output` callback, output will be empty and callback is invoked instead.

  Returns `{:error, reason}` if the data is malformed.
  """
  @spec decode(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def decode(%__MODULE__{} = decoder, chunk) when is_binary(chunk) do
    decoder = %{decoder | buffer: <<decoder.buffer::binary, chunk::binary>>}
    process(decoder)
  end

  @doc """
  Signal end of input and get final results.

  Returns `{:done, output, bytes_consumed}` on success.
  Returns `{:error, :incomplete}` if more data was expected.
  """
  @spec finish(t()) :: {:done, binary(), non_neg_integer()} | {:error, term()}
  def finish(%__MODULE__{phase: :done} = decoder) do
    # Any remaining pending_output was already returned by decode
    # Round up bytes consumed if we're mid-byte
    consumed =
      if decoder.bit_offset > 0 do
        decoder.bytes_consumed + 1
      else
        decoder.bytes_consumed
      end

    {:done, <<>>, consumed}
  end

  def finish(%__MODULE__{}) do
    {:error, :incomplete}
  end

  # Main processing loop - process as much as possible with available data
  defp process(decoder) do
    case step(decoder) do
      {:continue, decoder} ->
        process(decoder)

      {:need_more, decoder} ->
        output = flush_output(decoder)
        {:ok, output, %{decoder | pending_output: <<>>}}

      {:done, decoder} ->
        output = flush_output(decoder)
        {:ok, output, %{decoder | pending_output: <<>>}}

      {:error, _} = err ->
        err
    end
  end

  defp flush_output(%{on_output: nil, pending_output: output}), do: output

  defp flush_output(%{on_output: callback, pending_output: output}) when byte_size(output) > 0 do
    callback.(output)
    <<>>
  end

  defp flush_output(_), do: <<>>

  # Step through decoder state machine
  defp step(%{phase: :zlib_header} = decoder) do
    if byte_size(decoder.buffer) >= 2 do
      <<cmf, flg, rest::binary>> = decoder.buffer

      with :ok <- validate_compression_method(cmf),
           :ok <- validate_header_checksum(cmf, flg),
           :ok <- validate_no_preset_dict(flg) do
        {:continue,
         %{
           decoder
           | buffer: rest,
             bytes_consumed: decoder.bytes_consumed + 2,
             phase: :block_header
         }}
      end
    else
      {:need_more, decoder}
    end
  end

  defp step(%{phase: :block_header} = decoder) do
    case read_bits(decoder, 3) do
      {:ok, header, decoder} ->
        is_final = (header &&& 1) == 1
        btype = header >>> 1

        decoder = %{decoder | is_final_block: is_final}

        case btype do
          @block_stored ->
            # Align to byte boundary
            decoder = align_to_byte(decoder)
            {:continue, %{decoder | phase: :stored_len}}

          @block_fixed ->
            {lit_table, dist_table} = get_fixed_tables()

            {:continue,
             %{
               decoder
               | phase: :huffman,
                 lit_table: lit_table,
                 dist_table: dist_table,
                 lit_bits: 9,
                 dist_bits: 5
             }}

          @block_dynamic ->
            {:continue, %{decoder | phase: :dynamic_header, dynamic_state: :read_counts}}

          3 ->
            {:error, :reserved_block_type}
        end

      {:need_more, decoder} ->
        {:need_more, decoder}
    end
  end

  defp step(%{phase: :stored_len} = decoder) do
    if byte_size(decoder.buffer) >= 4 do
      <<len::little-16, nlen::little-16, rest::binary>> = decoder.buffer

      if Bitwise.bxor(len, nlen) == 0xFFFF do
        {:continue,
         %{
           decoder
           | buffer: rest,
             bytes_consumed: decoder.bytes_consumed + 4,
             phase: :stored_data,
             stored_remaining: len
         }}
      else
        {:error, :invalid_stored_block_length}
      end
    else
      {:need_more, decoder}
    end
  end

  defp step(%{phase: :stored_data, stored_remaining: 0} = decoder) do
    if decoder.is_final_block do
      decoder = consume_adler32_if_zlib(decoder)
      {:done, %{decoder | phase: :done}}
    else
      {:continue, %{decoder | phase: :block_header}}
    end
  end

  defp step(%{phase: :stored_data, stored_remaining: remaining} = decoder) do
    available = byte_size(decoder.buffer)

    if available > 0 do
      to_copy = min(available, remaining)
      <<chunk::binary-size(to_copy), rest::binary>> = decoder.buffer

      decoder = emit_output(decoder, chunk)

      {:continue,
       %{
         decoder
         | buffer: rest,
           bytes_consumed: decoder.bytes_consumed + to_copy,
           stored_remaining: remaining - to_copy
       }}
    else
      {:need_more, decoder}
    end
  end

  defp step(%{phase: :dynamic_header} = decoder) do
    step_dynamic_header(decoder)
  end

  defp step(%{phase: :huffman} = decoder) do
    step_huffman(decoder)
  end

  defp step(%{phase: :done} = decoder) do
    {:done, decoder}
  end

  # Dynamic Huffman header parsing (multi-step state machine)
  defp step_dynamic_header(%{dynamic_state: :read_counts} = decoder) do
    case read_bits(decoder, 14) do
      {:ok, bits, decoder} ->
        hlit = (bits &&& 0x1F) + 257
        hdist = (bits >>> 5 &&& 0x1F) + 1
        hclen = (bits >>> 10 &&& 0x0F) + 4

        {:continue,
         %{
           decoder
           | dynamic_state: {:read_cl_lengths, hlit, hdist, hclen, 0, List.duplicate(0, 19)}
         }}

      {:need_more, decoder} ->
        {:need_more, decoder}
    end
  end

  defp step_dynamic_header(
         %{dynamic_state: {:read_cl_lengths, hlit, hdist, hclen, idx, lengths}} = decoder
       )
       when idx >= hclen do
    cl_table = build_table(List.to_tuple(lengths), 19, 7)
    total = hlit + hdist

    {:continue,
     %{decoder | dynamic_state: {:read_code_lengths, hlit, hdist, cl_table, total, []}}}
  end

  defp step_dynamic_header(
         %{dynamic_state: {:read_cl_lengths, hlit, hdist, hclen, idx, lengths}} = decoder
       ) do
    case read_bits(decoder, 3) do
      {:ok, len, decoder} ->
        pos = elem(@code_length_order, idx)
        lengths = List.replace_at(lengths, pos, len)

        {:continue,
         %{decoder | dynamic_state: {:read_cl_lengths, hlit, hdist, hclen, idx + 1, lengths}}}

      {:need_more, decoder} ->
        {:need_more, decoder}
    end
  end

  defp step_dynamic_header(
         %{dynamic_state: {:read_code_lengths, hlit, hdist, _cl_table, total, acc}} = decoder
       )
       when length(acc) >= total do
    all_lengths = Enum.reverse(acc) |> Enum.take(total)
    lit_lengths = Enum.take(all_lengths, hlit) |> List.to_tuple()
    dist_lengths = Enum.drop(all_lengths, hlit) |> List.to_tuple()

    lit_max = Enum.max(Tuple.to_list(lit_lengths))
    dist_max = max(Enum.max(Tuple.to_list(dist_lengths)), 1)

    lit_table = build_table(lit_lengths, hlit, min(lit_max, 15))
    dist_table = build_table(dist_lengths, hdist, min(dist_max, 15))

    {:continue,
     %{
       decoder
       | phase: :huffman,
         lit_table: lit_table,
         dist_table: dist_table,
         lit_bits: min(lit_max, 15),
         dist_bits: min(dist_max, 15),
         dynamic_state: nil
     }}
  end

  defp step_dynamic_header(
         %{dynamic_state: {:read_code_lengths, hlit, hdist, cl_table, total, acc}} = decoder
       ) do
    case decode_symbol(decoder, cl_table, 7) do
      {:ok, symbol, decoder} when symbol <= 15 ->
        {:continue,
         %{
           decoder
           | dynamic_state: {:read_code_lengths, hlit, hdist, cl_table, total, [symbol | acc]}
         }}

      {:ok, 16, decoder} ->
        {:continue,
         %{
           decoder
           | dynamic_state: {:repeat_prev, hlit, hdist, cl_table, total, acc}
         }}

      {:ok, 17, decoder} ->
        {:continue,
         %{
           decoder
           | dynamic_state: {:repeat_zero_short, hlit, hdist, cl_table, total, acc}
         }}

      {:ok, 18, decoder} ->
        {:continue,
         %{
           decoder
           | dynamic_state: {:repeat_zero_long, hlit, hdist, cl_table, total, acc}
         }}

      {:need_more, decoder} ->
        {:need_more, decoder}

      {:error, _} = err ->
        err
    end
  end

  defp step_dynamic_header(
         %{dynamic_state: {:repeat_prev, hlit, hdist, cl_table, total, acc}} = decoder
       ) do
    case read_bits(decoder, 2) do
      {:ok, extra, decoder} ->
        prev = if acc == [], do: 0, else: hd(acc)
        new_acc = List.duplicate(prev, extra + 3) ++ acc

        {:continue,
         %{decoder | dynamic_state: {:read_code_lengths, hlit, hdist, cl_table, total, new_acc}}}

      {:need_more, decoder} ->
        {:need_more, decoder}
    end
  end

  defp step_dynamic_header(
         %{dynamic_state: {:repeat_zero_short, hlit, hdist, cl_table, total, acc}} = decoder
       ) do
    case read_bits(decoder, 3) do
      {:ok, extra, decoder} ->
        new_acc = List.duplicate(0, extra + 3) ++ acc

        {:continue,
         %{decoder | dynamic_state: {:read_code_lengths, hlit, hdist, cl_table, total, new_acc}}}

      {:need_more, decoder} ->
        {:need_more, decoder}
    end
  end

  defp step_dynamic_header(
         %{dynamic_state: {:repeat_zero_long, hlit, hdist, cl_table, total, acc}} = decoder
       ) do
    case read_bits(decoder, 7) do
      {:ok, extra, decoder} ->
        new_acc = List.duplicate(0, extra + 11) ++ acc

        {:continue,
         %{decoder | dynamic_state: {:read_code_lengths, hlit, hdist, cl_table, total, new_acc}}}

      {:need_more, decoder} ->
        {:need_more, decoder}
    end
  end

  # Huffman decoding with state-based resumption for back-references
  # backref_state can be:
  #   nil - normal decoding
  #   {:have_length, len_symbol} - decoded length symbol, need extra bits
  #   {:have_length_value, length} - have length, need distance symbol
  #   {:have_distance, length, dist_code} - have distance symbol, need extra bits

  defp step_huffman(%{backref_state: nil} = decoder) do
    case decode_symbol(decoder, decoder.lit_table, decoder.lit_bits) do
      {:ok, symbol, decoder} when symbol < 256 ->
        # Literal byte
        decoder = emit_output(decoder, <<symbol>>)
        {:continue, decoder}

      {:ok, 256, decoder} ->
        # End of block
        if decoder.is_final_block do
          decoder = consume_adler32_if_zlib(decoder)
          {:done, %{decoder | phase: :done}}
        else
          {:continue, %{decoder | phase: :block_header}}
        end

      {:ok, symbol, decoder} when symbol <= 285 ->
        # Length/distance pair - start backref decoding
        decode_backref_length_extra(decoder, symbol)

      {:ok, symbol, _decoder} ->
        {:error, {:invalid_literal_symbol, symbol}}

      {:need_more, decoder} ->
        {:need_more, decoder}

      {:error, _} = err ->
        err
    end
  end

  defp step_huffman(%{backref_state: {:have_length, len_symbol}} = decoder) do
    decode_backref_length_extra(decoder, len_symbol)
  end

  defp step_huffman(%{backref_state: {:have_length_value, length}} = decoder) do
    decode_backref_distance(decoder, length)
  end

  defp step_huffman(%{backref_state: {:have_distance, length, dist_code}} = decoder) do
    decode_backref_distance_extra(decoder, length, dist_code)
  end

  # Decode length extra bits
  defp decode_backref_length_extra(decoder, len_symbol) do
    len_code = len_symbol - 257
    extra_bits = elem(@length_extra_bits, len_code)
    base_len = elem(@length_base, len_code)

    case read_bits(decoder, extra_bits) do
      {:ok, extra, decoder} ->
        length = base_len + extra
        decoder = %{decoder | backref_state: {:have_length_value, length}}
        decode_backref_distance(decoder, length)

      {:need_more, decoder} ->
        # Save state to resume
        {:need_more, %{decoder | backref_state: {:have_length, len_symbol}}}
    end
  end

  # Decode distance symbol
  defp decode_backref_distance(decoder, length) do
    case decode_symbol(decoder, decoder.dist_table, decoder.dist_bits) do
      {:ok, dist_code, decoder} when dist_code <= 29 ->
        decoder = %{decoder | backref_state: {:have_distance, length, dist_code}}
        decode_backref_distance_extra(decoder, length, dist_code)

      {:ok, dist_code, _decoder} ->
        {:error, {:invalid_distance_code, dist_code}}

      {:need_more, decoder} ->
        {:need_more, %{decoder | backref_state: {:have_length_value, length}}}

      {:error, _} = err ->
        err
    end
  end

  # Decode distance extra bits and emit copy
  defp decode_backref_distance_extra(decoder, length, dist_code) do
    dist_extra_bits = elem(@dist_extra_bits, dist_code)
    dist_base = elem(@dist_base, dist_code)

    case read_bits(decoder, dist_extra_bits) do
      {:ok, extra, decoder} ->
        distance = dist_base + extra
        decoder = copy_from_window(decoder, distance, length)
        # Clear backref state
        {:continue, %{decoder | backref_state: nil}}

      {:need_more, decoder} ->
        {:need_more, %{decoder | backref_state: {:have_distance, length, dist_code}}}
    end
  end

  # Output and window management
  defp emit_output(decoder, data) do
    new_window = <<decoder.window::binary, data::binary>>

    # Keep only last 32KB for back-references
    new_window =
      if byte_size(new_window) > @window_size do
        excess = byte_size(new_window) - @window_size
        binary_part(new_window, excess, @window_size)
      else
        new_window
      end

    new_pending = <<decoder.pending_output::binary, data::binary>>

    # If callback is set and we have enough data, flush
    if decoder.on_output != nil and byte_size(new_pending) > 8192 do
      decoder.on_output.(new_pending)
      %{decoder | window: new_window, pending_output: <<>>}
    else
      %{decoder | window: new_window, pending_output: new_pending}
    end
  end

  defp copy_from_window(decoder, distance, length) do
    window = decoder.window
    window_size = byte_size(window)
    start = window_size - distance

    data =
      if distance >= length do
        binary_part(window, start, length)
      else
        # Overlapping copy
        pattern = binary_part(window, start, distance)
        build_pattern(pattern, length, <<>>)
      end

    emit_output(decoder, data)
  end

  defp build_pattern(_pattern, 0, acc), do: acc

  defp build_pattern(pattern, remaining, acc) when remaining >= byte_size(pattern) do
    build_pattern(pattern, remaining - byte_size(pattern), <<acc::binary, pattern::binary>>)
  end

  defp build_pattern(pattern, remaining, acc) do
    <<acc::binary, binary_part(pattern, 0, remaining)::binary>>
  end

  # Bit reading utilities
  defp read_bits(decoder, 0), do: {:ok, 0, decoder}

  defp read_bits(decoder, count) do
    read_bits_acc(decoder, count, 0, 0)
  end

  defp read_bits_acc(decoder, 0, value, _shift) do
    {:ok, value, decoder}
  end

  defp read_bits_acc(decoder, count, value, shift) do
    if byte_size(decoder.buffer) == 0 do
      {:need_more, decoder}
    else
      <<byte, rest::binary>> = decoder.buffer
      bits_available = 8 - decoder.bit_offset
      bits_to_read = min(count, bits_available)

      mask = (1 <<< bits_to_read) - 1
      bits = byte >>> decoder.bit_offset &&& mask
      value = value ||| bits <<< shift

      new_bit_offset = decoder.bit_offset + bits_to_read

      if new_bit_offset >= 8 do
        decoder = %{
          decoder
          | buffer: rest,
            bit_offset: 0,
            bytes_consumed: decoder.bytes_consumed + 1
        }

        read_bits_acc(decoder, count - bits_to_read, value, shift + bits_to_read)
      else
        decoder = %{decoder | bit_offset: new_bit_offset}
        read_bits_acc(decoder, count - bits_to_read, value, shift + bits_to_read)
      end
    end
  end

  defp align_to_byte(%{bit_offset: 0} = decoder), do: decoder

  defp align_to_byte(decoder) do
    <<_byte, rest::binary>> = decoder.buffer
    %{decoder | buffer: rest, bit_offset: 0, bytes_consumed: decoder.bytes_consumed + 1}
  end

  defp decode_symbol(decoder, table, max_bits) do
    case peek_bits(decoder, max_bits) do
      {:ok, bits, available} ->
        packed = elem(table, bits)

        if packed == @invalid_entry do
          {:error, :invalid_huffman_code}
        else
          symbol = packed >>> 4
          len = packed &&& 0xF

          if len <= available do
            {:ok, symbol, consume_bits(decoder, len)}
          else
            {:need_more, decoder}
          end
        end

      {:need_more, decoder} ->
        {:need_more, decoder}
    end
  end

  defp peek_bits(decoder, count) do
    peek_bits_acc(decoder, count, 0, 0, decoder.bit_offset)
  end

  defp peek_bits_acc(_decoder, 0, value, shift, _bit_offset) do
    {:ok, value, shift}
  end

  defp peek_bits_acc(decoder, count, value, shift, bit_offset) do
    byte_idx = div(shift + decoder.bit_offset, 8)

    if byte_idx >= byte_size(decoder.buffer) do
      {:ok, value, shift}
    else
      byte = :binary.at(decoder.buffer, byte_idx)
      current_bit_offset = rem(shift + decoder.bit_offset, 8)
      bits_available = 8 - current_bit_offset
      bits_to_read = min(count, bits_available)

      mask = (1 <<< bits_to_read) - 1
      bits = byte >>> current_bit_offset &&& mask
      value = value ||| bits <<< shift

      peek_bits_acc(decoder, count - bits_to_read, value, shift + bits_to_read, bit_offset)
    end
  end

  defp consume_bits(decoder, count) do
    total_bits = decoder.bit_offset + count
    bytes_to_consume = div(total_bits, 8)
    new_bit_offset = rem(total_bits, 8)

    new_buffer =
      binary_part(decoder.buffer, bytes_to_consume, byte_size(decoder.buffer) - bytes_to_consume)

    %{
      decoder
      | buffer: new_buffer,
        bit_offset: new_bit_offset,
        bytes_consumed: decoder.bytes_consumed + bytes_to_consume
    }
  end

  defp consume_adler32_if_zlib(%{format: :zlib} = decoder) do
    # Skip 4-byte Adler-32 checksum
    if byte_size(decoder.buffer) >= 4 do
      <<_adler::binary-size(4), rest::binary>> = decoder.buffer
      %{decoder | buffer: rest, bytes_consumed: decoder.bytes_consumed + 4}
    else
      decoder
    end
  end

  defp consume_adler32_if_zlib(decoder), do: decoder

  # Validation helpers
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

  # Fixed Huffman tables
  defp get_fixed_tables do
    lit_table = build_fixed_lit_table()
    dist_table = build_fixed_dist_table()
    {lit_table, dist_table}
  end

  defp build_fixed_lit_table do
    lengths_list = for i <- 0..287, do: elem(@fixed_lit_lengths, i)
    build_table(List.to_tuple(lengths_list), 288, 9)
  end

  defp build_fixed_dist_table do
    lengths_list = for i <- 0..31, do: elem(@fixed_dist_lengths, i)
    build_table(List.to_tuple(lengths_list), 32, 5)
  end

  # Table building (same algorithm as main module)
  defp build_table(lengths, max_code, max_bits) when max_bits > 0 do
    lengths_list = for i <- 0..(max_code - 1), do: elem(lengths, i)
    actual_max = Enum.max(lengths_list)

    if actual_max == 0 do
      List.duplicate(@invalid_entry, 1 <<< max_bits) |> List.to_tuple()
    else
      build_table_from_lengths(lengths_list, actual_max, max_bits)
    end
  end

  defp build_table(_lengths, _max_code, 0) do
    {@invalid_entry}
  end

  defp build_table_from_lengths(lengths_list, actual_max, max_bits) do
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
        {0, _sym}, {map, nc} ->
          {map, nc}

        {len, sym}, {map, nc} ->
          code = Map.get(nc, len, 0)
          nc = Map.put(nc, len, code + 1)
          reversed = reverse_bits(code, len)
          {Map.put(map, {reversed, len}, sym), nc}
      end)

    table_size = 1 <<< max_bits

    entries =
      for pattern <- 0..(table_size - 1) do
        Enum.find_value(1..actual_max, fn len ->
          mask = (1 <<< len) - 1
          code = pattern &&& mask

          case Map.get(code_map, {code, len}) do
            nil -> nil
            symbol -> symbol <<< 4 ||| len
          end
        end) || @invalid_entry
      end

    List.to_tuple(entries)
  end

  defp reverse_bits(code, len) do
    Enum.reduce(1..len, {code, 0}, fn _, {v, acc} ->
      {v >>> 1, acc <<< 1 ||| (v &&& 1)}
    end)
    |> elem(1)
  end
end
