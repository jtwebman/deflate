defmodule Deflate.DecoderTest do
  use ExUnit.Case, async: true

  alias Deflate.Decoder

  describe "new/1" do
    test "creates decoder with default options" do
      assert {:ok, decoder} = Decoder.new()
      assert decoder.format == :zlib
      assert decoder.phase == :zlib_header
    end

    test "creates raw decoder" do
      assert {:ok, decoder} = Decoder.new(format: :raw)
      assert decoder.format == :raw
      assert decoder.phase == :block_header
    end

    test "accepts on_output callback" do
      callback = fn _chunk -> :ok end
      assert {:ok, decoder} = Decoder.new(on_output: callback)
      assert decoder.on_output == callback
    end
  end

  describe "decode/2 - single chunk" do
    test "decodes complete zlib data in one chunk" do
      original = "hello world"
      compressed = :zlib.compress(original)

      {:ok, decoder} = Decoder.new()
      {:ok, output, decoder} = Decoder.decode(decoder, compressed)
      {:done, final, _consumed} = Decoder.finish(decoder)

      assert output <> final == original
    end

    test "decodes complete raw deflate in one chunk" do
      original = "hello world"
      compressed = :zlib.compress(original)
      # Strip zlib wrapper
      raw_len = byte_size(compressed) - 6
      raw = binary_part(compressed, 2, raw_len)

      {:ok, decoder} = Decoder.new(format: :raw)
      {:ok, output, decoder} = Decoder.decode(decoder, raw)
      {:done, final, _consumed} = Decoder.finish(decoder)

      assert output <> final == original
    end
  end

  describe "decode/2 - chunked input" do
    test "handles 1-byte chunks" do
      original = "hello world"
      compressed = :zlib.compress(original)

      {:ok, decoder} = Decoder.new()

      # Feed one byte at a time
      {decoder, outputs} =
        compressed
        |> :binary.bin_to_list()
        |> Enum.reduce({decoder, []}, fn byte, {dec, outs} ->
          {:ok, out, dec} = Decoder.decode(dec, <<byte>>)
          {dec, [out | outs]}
        end)

      {:done, final, _consumed} = Decoder.finish(decoder)

      result = (Enum.reverse(outputs) ++ [final]) |> IO.iodata_to_binary()
      assert result == original
    end

    test "handles random-sized chunks" do
      original = String.duplicate("the quick brown fox ", 100)
      compressed = :zlib.compress(original)

      {:ok, decoder} = Decoder.new()

      # Split into random-sized chunks
      chunks = random_chunks(compressed, 1, 50)

      {decoder, outputs} =
        Enum.reduce(chunks, {decoder, []}, fn chunk, {dec, outs} ->
          {:ok, out, dec} = Decoder.decode(dec, chunk)
          {dec, [out | outs]}
        end)

      {:done, final, _consumed} = Decoder.finish(decoder)

      result = (Enum.reverse(outputs) ++ [final]) |> IO.iodata_to_binary()
      assert result == original
    end

    test "handles large data in chunks" do
      original = :crypto.strong_rand_bytes(50_000)
      compressed = :zlib.compress(original)

      {:ok, decoder} = Decoder.new()

      # 1KB chunks
      chunks = chunk_binary(compressed, 1024)

      {decoder, outputs} =
        Enum.reduce(chunks, {decoder, []}, fn chunk, {dec, outs} ->
          {:ok, out, dec} = Decoder.decode(dec, chunk)
          {dec, [out | outs]}
        end)

      {:done, final, _consumed} = Decoder.finish(decoder)

      result = (Enum.reverse(outputs) ++ [final]) |> IO.iodata_to_binary()
      assert result == original
    end
  end

  describe "decode/2 - with callback" do
    test "invokes callback with output chunks" do
      original = String.duplicate("callback test ", 1000)
      compressed = :zlib.compress(original)

      test_pid = self()

      {:ok, decoder} =
        Decoder.new(
          on_output: fn chunk ->
            send(test_pid, {:chunk, chunk})
          end
        )

      {:ok, _output, decoder} = Decoder.decode(decoder, compressed)
      {:done, _final, _consumed} = Decoder.finish(decoder)

      # Collect all chunks
      chunks = collect_chunks()
      result = IO.iodata_to_binary(chunks)
      assert result == original
    end
  end

  describe "byte consumption tracking" do
    test "tracks bytes consumed for concatenated streams" do
      data1 = "first stream"
      data2 = "second stream"

      compressed1 = :zlib.compress(data1)
      compressed2 = :zlib.compress(data2)
      combined = compressed1 <> compressed2

      # Decode first stream
      {:ok, decoder1} = Decoder.new()
      {:ok, out1, decoder1} = Decoder.decode(decoder1, combined)
      {:done, final1, consumed1} = Decoder.finish(decoder1)

      assert out1 <> final1 == data1
      assert consumed1 == byte_size(compressed1)

      # Decode second stream from remaining
      remaining = binary_part(combined, consumed1, byte_size(combined) - consumed1)

      {:ok, decoder2} = Decoder.new()
      {:ok, out2, decoder2} = Decoder.decode(decoder2, remaining)
      {:done, final2, consumed2} = Decoder.finish(decoder2)

      assert out2 <> final2 == data2
      assert consumed2 == byte_size(compressed2)
    end
  end

  describe "error handling" do
    test "returns error for invalid zlib header" do
      {:ok, decoder} = Decoder.new()
      result = Decoder.decode(decoder, <<0x00, 0x00>>)
      assert {:error, {:invalid_compression_method, _}} = result
    end

    test "returns error for incomplete data" do
      {:ok, decoder} = Decoder.new()
      {:ok, _output, decoder} = Decoder.decode(decoder, <<0x78, 0x9C>>)
      assert {:error, :incomplete} = Decoder.finish(decoder)
    end
  end

  describe "block types" do
    test "handles stored blocks in chunks" do
      # Create stored block manually
      data = "stored block data"
      len = byte_size(data)
      nlen = Bitwise.bxor(len, 0xFFFF)
      stored = <<0x01>> <> <<len::little-16, nlen::little-16>> <> data

      {:ok, decoder} = Decoder.new(format: :raw)

      # Feed in small chunks
      chunks = chunk_binary(stored, 3)

      {decoder, outputs} =
        Enum.reduce(chunks, {decoder, []}, fn chunk, {dec, outs} ->
          {:ok, out, dec} = Decoder.decode(dec, chunk)
          {dec, [out | outs]}
        end)

      {:done, final, _} = Decoder.finish(decoder)

      result = (Enum.reverse(outputs) ++ [final]) |> IO.iodata_to_binary()
      assert result == data
    end

    test "handles fixed Huffman blocks in chunks" do
      original = "fixed huffman test"
      compressed = :zlib.compress(original)

      {:ok, decoder} = Decoder.new()

      chunks = chunk_binary(compressed, 5)

      {decoder, outputs} =
        Enum.reduce(chunks, {decoder, []}, fn chunk, {dec, outs} ->
          {:ok, out, dec} = Decoder.decode(dec, chunk)
          {dec, [out | outs]}
        end)

      {:done, final, _} = Decoder.finish(decoder)

      result = (Enum.reverse(outputs) ++ [final]) |> IO.iodata_to_binary()
      assert result == original
    end

    test "handles dynamic Huffman blocks in chunks" do
      # Longer data typically uses dynamic Huffman
      original = String.duplicate("dynamic huffman ", 100)
      compressed = :zlib.compress(original)

      {:ok, decoder} = Decoder.new()

      chunks = chunk_binary(compressed, 10)

      {decoder, outputs} =
        Enum.reduce(chunks, {decoder, []}, fn chunk, {dec, outs} ->
          {:ok, out, dec} = Decoder.decode(dec, chunk)
          {dec, [out | outs]}
        end)

      {:done, final, _} = Decoder.finish(decoder)

      result = (Enum.reverse(outputs) ++ [final]) |> IO.iodata_to_binary()
      assert result == original
    end
  end

  describe "back-references" do
    test "handles back-references with chunked input" do
      # Highly repetitive data = lots of back-references
      original = String.duplicate("ab", 1000)
      compressed = :zlib.compress(original)

      {:ok, decoder} = Decoder.new()

      chunks = chunk_binary(compressed, 7)

      {decoder, outputs} =
        Enum.reduce(chunks, {decoder, []}, fn chunk, {dec, outs} ->
          {:ok, out, dec} = Decoder.decode(dec, chunk)
          {dec, [out | outs]}
        end)

      {:done, final, _} = Decoder.finish(decoder)

      result = (Enum.reverse(outputs) ++ [final]) |> IO.iodata_to_binary()
      assert result == original
    end

    test "handles overlapping back-references" do
      original = String.duplicate("x", 1000)
      compressed = :zlib.compress(original)

      {:ok, decoder} = Decoder.new()

      chunks = chunk_binary(compressed, 3)

      {decoder, outputs} =
        Enum.reduce(chunks, {decoder, []}, fn chunk, {dec, outs} ->
          {:ok, out, dec} = Decoder.decode(dec, chunk)
          {dec, [out | outs]}
        end)

      {:done, final, _} = Decoder.finish(decoder)

      result = (Enum.reverse(outputs) ++ [final]) |> IO.iodata_to_binary()
      assert result == original
    end
  end

  # Helper functions

  defp chunk_binary(binary, chunk_size) do
    chunk_binary(binary, chunk_size, [])
  end

  defp chunk_binary(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp chunk_binary(binary, chunk_size, acc) when byte_size(binary) <= chunk_size do
    Enum.reverse([binary | acc])
  end

  defp chunk_binary(binary, chunk_size, acc) do
    <<chunk::binary-size(chunk_size), rest::binary>> = binary
    chunk_binary(rest, chunk_size, [chunk | acc])
  end

  defp random_chunks(binary, min_size, max_size) do
    random_chunks(binary, min_size, max_size, [])
  end

  defp random_chunks(<<>>, _min, _max, acc), do: Enum.reverse(acc)

  defp random_chunks(binary, min_size, max_size, acc) do
    size = min(Enum.random(min_size..max_size), byte_size(binary))
    <<chunk::binary-size(size), rest::binary>> = binary
    random_chunks(rest, min_size, max_size, [chunk | acc])
  end

  defp collect_chunks do
    collect_chunks([])
  end

  defp collect_chunks(acc) do
    receive do
      {:chunk, chunk} -> collect_chunks([chunk | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
